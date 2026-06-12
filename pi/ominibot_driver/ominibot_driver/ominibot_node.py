#!/usr/bin/env python3
# coding=utf-8
"""OminiBot HV v1.2 ROS 2 驅動節點(大括號協定,參考 OminiBot_HV_Meca.py)。

/cmd_vel(Twist)→ robot_speed(lx, ly, az),單位直接是 m/s、rad/s,
不需 raw 標定;板子內建麥克納姆運動學。

安全機制:
  - cmd_timeout(預設 0.5 s)沒收到 /cmd_vel → forced_stop()(watchdog)
  - 20 Hz 重發目前速度;節點關閉時 forced_stop()

里程計:板子主動串流遙測(實測車速 + IMU 四元數 + 電池):
  - 速度積分位姿、yaw 採 IMU 四元數(較準;use_imu_yaw=false 改積分)
  - 發布 /odom 與 odom→base_link TF、/battery_voltage
  - 遙測中斷時退回指令速度開環積分(open_loop_fallback)
"""
import math

import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist, TransformStamped
from nav_msgs.msg import Odometry
from std_msgs.msg import Float32
from tf2_ros import TransformBroadcaster

from .ominibot_protocol import OminibotHV


class OminibotNode(Node):

    def __init__(self):
        super().__init__("ominibot_node")
        # --- 連線與安全 ---
        self.declare_parameter("port", "/dev/ominibot")
        self.declare_parameter("baud", 115200)
        self.declare_parameter("cmd_timeout", 0.5)     # 秒;watchdog
        self.declare_parameter("max_linear", 0.5)      # m/s 上限(保險)
        self.declare_parameter("max_angular", 1.5)     # rad/s 上限
        # 軸正負號(實測方向相反時改 -1.0)
        self.declare_parameter("x_sign", 1.0)
        self.declare_parameter("y_sign", 1.0)
        self.declare_parameter("z_sign", 1.0)
        # --- 車體參數(0x23/0x24/0x40 初始化;單位照板子協定) ---
        self.declare_parameter("wheel_diameter", 60)   # mm
        self.declare_parameter("wheel_space", 110)     # mm 輪距
        self.declare_parameter("axle_space", 110)      # mm 軸距
        self.declare_parameter("gear_ratio", 55)
        self.declare_parameter("encoder_ppr", 165)
        self.declare_parameter("motor_pwm_max", 3600)
        self.declare_parameter("motor_pwm_min", 2100)
        # --- 里程計 ---
        self.declare_parameter("publish_odom", True)
        self.declare_parameter("publish_tf", True)
        self.declare_parameter("odom_frame", "odom")
        self.declare_parameter("base_frame", "base_link")
        self.declare_parameter("use_imu_yaw", True)    # yaw 用 IMU 四元數
        self.declare_parameter("open_loop_fallback", True)
        self.declare_parameter("battery_scale", 0.001)  # 電池 raw = mV(實測 10800 ≈ 10.8 V/3S)

        p = lambda name: self.get_parameter(name).value
        self.cmd_timeout = p("cmd_timeout")
        self.max_linear, self.max_angular = p("max_linear"), p("max_angular")
        self.x_sign, self.y_sign, self.z_sign = p("x_sign"), p("y_sign"), p("z_sign")
        self.odom_frame, self.base_frame = p("odom_frame"), p("base_frame")
        self.use_imu_yaw = p("use_imu_yaw")
        self.open_loop_fallback = p("open_loop_fallback")
        self.battery_scale = p("battery_scale")
        self.publish_odom = p("publish_odom")

        self.get_logger().info(f"開啟 OminiBot HV {p('port')}(大括號協定,初始化中…)")
        self.bot = OminibotHV(
            port=p("port"), baud=p("baud"),
            wheel_diameter=p("wheel_diameter"), wheel_space=p("wheel_space"),
            axle_space=p("axle_space"), gear_ratio=p("gear_ratio"),
            encoder_ppr=p("encoder_ppr"),
            motor_pwm_max=p("motor_pwm_max"), motor_pwm_min=p("motor_pwm_min"))
        self.get_logger().info("板子初始化完成(forced_stop + 系統/車體/PID 設定)")

        # 目前指令(SI)與時間戳
        self.cmd = (0.0, 0.0, 0.0)
        self.last_cmd_time = self.get_clock().now()
        self.timed_out = False

        self.create_subscription(Twist, "/cmd_vel", self.on_cmd_vel, 10)
        self.create_timer(0.05, self.tick)   # 20 Hz 重發 + watchdog

        # --- 里程計與遙測 ---
        self.pose = [0.0, 0.0, 0.0]
        self.yaw_offset = None        # IMU yaw 歸零用
        self.last_telemetry_time = None
        self.telemetry_count = 0
        if self.publish_odom:
            self.odom_pub = self.create_publisher(Odometry, "/odom", 10)
            self.battery_pub = self.create_publisher(Float32, "/battery_voltage", 10)
            self.tf_broadcaster = TransformBroadcaster(self) if p("publish_tf") else None
            self.bot.start_reader(on_telemetry=self.on_telemetry)

    # ------------------------------------------------------------------
    # /cmd_vel → robot_speed
    # ------------------------------------------------------------------

    def on_cmd_vel(self, msg: Twist):
        clamp = lambda v, m: max(-m, min(m, v))
        self.cmd = (
            clamp(msg.linear.x * self.x_sign, self.max_linear),
            clamp(msg.linear.y * self.y_sign, self.max_linear),
            clamp(msg.angular.z * self.z_sign, self.max_angular),
        )
        self.last_cmd_time = self.get_clock().now()
        if self.timed_out:
            self.timed_out = False
            self.get_logger().info("恢復收到 /cmd_vel")

    def tick(self):
        """20 Hz:重發速度;逾時 forced_stop;必要時開環里程計"""
        elapsed = (self.get_clock().now() - self.last_cmd_time).nanoseconds / 1e9
        if elapsed > self.cmd_timeout:
            if not self.timed_out:
                self.timed_out = True
                self.get_logger().warning(f"{self.cmd_timeout}s 未收到 /cmd_vel,forced_stop")
            self.bot.forced_stop()
        else:
            self.bot.robot_speed(*self.cmd)

        # 遙測中斷時(>1s)用指令速度開環積分,讓建圖不斷鏈
        if (self.publish_odom and self.open_loop_fallback
                and self._telemetry_stale()):
            vx, vy, wz = (0.0, 0.0, 0.0) if self.timed_out else self.cmd
            self.integrate(vx, vy, wz, dt=0.05, yaw_abs=None)
            self.publish_odometry(vx, vy, wz)

    def _telemetry_stale(self):
        if self.last_telemetry_time is None:
            return True
        return (self.get_clock().now() - self.last_telemetry_time).nanoseconds / 1e9 > 1.0

    # ------------------------------------------------------------------
    # 遙測 → /odom + TF + 電池
    # ------------------------------------------------------------------

    def on_telemetry(self, t):
        """板子遙測幀(串列讀取執行緒呼叫):實測車速 + IMU 四元數 + 電池"""
        if not t["bcc_ok"]:
            return
        now = self.get_clock().now()
        prev = self.last_telemetry_time
        self.last_telemetry_time = now
        if prev is None:
            return
        dt = (now - prev).nanoseconds / 1e9
        if dt <= 0 or dt > 1.0:
            return

        yaw_abs = None
        if self.use_imu_yaw:
            qw, qx, qy, qz = t["quat"]
            norm = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
            if norm > 0.5:   # 四元數有效才用
                yaw = math.atan2(2 * (qw * qz + qx * qy),
                                 1 - 2 * (qy * qy + qz * qz))
                if self.yaw_offset is None:
                    self.yaw_offset = yaw
                yaw_abs = yaw - self.yaw_offset

        self.integrate(t["vx"], t["vy"], t["wz"], dt, yaw_abs)
        self.publish_odometry(t["vx"], t["vy"], t["wz"])

        # 電池:每 ~50 幀發一次就夠
        self.telemetry_count += 1
        if self.telemetry_count % 50 == 1:
            msg = Float32()
            msg.data = float(t["battery_raw"]) * self.battery_scale
            self.battery_pub.publish(msg)

    def integrate(self, vx, vy, wz, dt, yaw_abs):
        """位姿積分;yaw_abs 非 None 時直接採用(IMU),否則積分 wz"""
        th = self.pose[2]
        self.pose[0] += (vx * math.cos(th) - vy * math.sin(th)) * dt
        self.pose[1] += (vx * math.sin(th) + vy * math.cos(th)) * dt
        self.pose[2] = yaw_abs if yaw_abs is not None else th + wz * dt

    def publish_odometry(self, vx, vy, wz):
        now = self.get_clock().now().to_msg()
        qz, qw = math.sin(self.pose[2] / 2), math.cos(self.pose[2] / 2)

        odom = Odometry()
        odom.header.stamp = now
        odom.header.frame_id = self.odom_frame
        odom.child_frame_id = self.base_frame
        odom.pose.pose.position.x = self.pose[0]
        odom.pose.pose.position.y = self.pose[1]
        odom.pose.pose.orientation.z = qz
        odom.pose.pose.orientation.w = qw
        odom.twist.twist.linear.x = float(vx)
        odom.twist.twist.linear.y = float(vy)
        odom.twist.twist.angular.z = float(wz)
        self.odom_pub.publish(odom)

        if self.tf_broadcaster:
            tf = TransformStamped()
            tf.header.stamp = now
            tf.header.frame_id = self.odom_frame
            tf.child_frame_id = self.base_frame
            tf.transform.translation.x = self.pose[0]
            tf.transform.translation.y = self.pose[1]
            tf.transform.rotation.z = qz
            tf.transform.rotation.w = qw
            self.tf_broadcaster.sendTransform(tf)

    def destroy_node(self):
        try:
            self.bot.close()   # 內含 forced_stop
        except Exception:
            pass
        super().destroy_node()


def main(args=None):
    rclpy.init(args=args)
    node = OminibotNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
