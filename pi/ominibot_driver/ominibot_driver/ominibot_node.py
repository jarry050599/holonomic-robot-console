#!/usr/bin/env python3
# coding=utf-8
"""OminiBot HV ROS 2 驅動節點(協定:github.com/iCShopMgr/OminiBotHV)。

訂閱 /cmd_vel(geometry_msgs/Twist)→ 換算 raw 速度幀寫底盤。
軸對應(官方文件;正負號可用參數調整,實測不符再調):
    ROS linear.x(前後) → 板子 Y 軸
    ROS linear.y(左右) → 板子 X 軸
    ROS angular.z(旋轉)→ 板子 Z 軸

安全機制:
  - cmd_timeout(預設 0.5 s)沒收到 /cmd_vel 自動停車(watchdog)
  - 以固定 20 Hz 重發目前速度幀,逾時後改發零速度幀
  - 節點關閉時送停車幀

里程計:板子 System mode bit6=1 時會回傳編碼器幀,
本節點以三全向輪正運動學解 (vx, vy, wz) 積分成 /odom 並廣播
odom→base_link TF(SLAM/Nav2 需要)。編碼器沒資料時(未上電或
未標定),改用「指令速度開環積分」當備援,讓建圖流程先能動。
encoder_scale 等參數需實測標定,未標定前 /odom 僅供相對參考。
"""
import math

import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist, TransformStamped
from nav_msgs.msg import Odometry
from tf2_ros import TransformBroadcaster

from .ominibot_protocol import OminibotHV


class OminibotNode(Node):

    def __init__(self):
        super().__init__("ominibot_node")
        # --- 連線與速度換算參數(scale 需實測標定) ---
        self.declare_parameter("port", "/dev/ominibot")
        self.declare_parameter("baud", 115200)
        # 保守映射:Mac 端上限 0.5 m/s、1.5 rad/s 都恰好對到 max_raw=300
        self.declare_parameter("linear_scale", 600.0)     # raw per m/s
        self.declare_parameter("angular_scale", 200.0)    # raw per rad/s
        self.declare_parameter("max_raw", 300)            # raw 絕對上限(標定前的保險)
        self.declare_parameter("cmd_timeout", 0.5)        # 秒;watchdog
        # 軸正負號(實測方向相反時把對應參數改 -1.0)
        self.declare_parameter("x_sign", 1.0)   # 板子 X(= ROS linear.y)
        self.declare_parameter("y_sign", 1.0)   # 板子 Y(= ROS linear.x)
        self.declare_parameter("z_sign", 1.0)   # 板子 Z(= ROS angular.z)
        # --- 里程計參數(標定用,皆為 ROS 參數) ---
        self.declare_parameter("publish_odom", True)
        self.declare_parameter("publish_tf", True)        # 廣播 odom→base_link
        self.declare_parameter("odom_frame", "odom")
        self.declare_parameter("base_frame", "base_link")
        self.declare_parameter("encoder_scale", 0.001)    # 編碼器「實際」raw → 輪面線速度 m/s
        self.declare_parameter("wheel_radius", 0.03)      # 輪半徑 m(encoder raw 為角速度時用)
        self.declare_parameter("robot_radius", 0.15)      # 輪心到車中心距離(輪距)m
        # 三輪安裝角(度):上游配置 back=MOTO1、right_front=MOTO2、left_front=MOTO3
        self.declare_parameter("wheel_angles_deg", [270.0, 30.0, 150.0])
        # 編碼器無資料時用指令速度開環積分(讓 SLAM 在標定前就能建圖)
        self.declare_parameter("open_loop_fallback", True)

        p = lambda name: self.get_parameter(name).value
        self.linear_scale = p("linear_scale")
        self.angular_scale = p("angular_scale")
        self.max_raw = p("max_raw")
        self.cmd_timeout = p("cmd_timeout")
        self.x_sign, self.y_sign, self.z_sign = p("x_sign"), p("y_sign"), p("z_sign")
        self.encoder_scale = p("encoder_scale")
        self.robot_radius = p("robot_radius")
        self.wheel_angles = [math.radians(a) for a in p("wheel_angles_deg")]
        self.odom_frame = p("odom_frame")
        self.base_frame = p("base_frame")
        self.publish_tf = p("publish_tf")
        self.open_loop_fallback = p("open_loop_fallback")

        self.get_logger().info(f"開啟 OminiBot HV 串列埠 {p('port')} (baud {p('baud')})")
        self.bot = OminibotHV(p("port"), p("baud"))

        # 目前目標速度(板子座標 raw)、原始 SI 指令(開環積分用)與時間戳
        self.target = (0, 0, 0)
        self.cmd_twist = (0.0, 0.0, 0.0)   # (vx, vy, wz) m/s, rad/s
        self.last_cmd_time = self.get_clock().now()
        self.timed_out = False

        self.create_subscription(Twist, "/cmd_vel", self.on_cmd_vel, 10)
        # 20 Hz 重發目前速度幀(逾時則發零),兼作 watchdog
        self.create_timer(0.05, self.tick)

        # --- 里程計 ---
        self.publish_odom = p("publish_odom")
        if self.publish_odom:
            self.odom_pub = self.create_publisher(Odometry, "/odom", 10)
            self.tf_broadcaster = TransformBroadcaster(self) if self.publish_tf else None
            self.pose = [0.0, 0.0, 0.0]          # x, y, theta(odom 座標)
            self.last_enc_time = None
            self.encoder_active = False         # 是否收過編碼器幀
            self.kinematics = self.make_kinematics()
            self.bot.start_reader(on_encoder=self.on_encoder)
            # 開啟編碼器回傳(bit6 不能記憶、斷電重置,讀-改-寫不影響存檔設定)
            if self.bot.enable_encoder_feedback():
                self.get_logger().info("已開啟編碼器回傳,/odom 用編碼器")
            elif self.open_loop_fallback:
                self.get_logger().warning(
                    "板子未回應 System mode 讀取,/odom 退回指令速度開環積分")
            else:
                self.get_logger().warning("板子未回應且未啟用開環備援,/odom 不會更新")

    # ------------------------------------------------------------------
    # /cmd_vel → 速度幀
    # ------------------------------------------------------------------

    def on_cmd_vel(self, msg: Twist):
        """收到速度指令:轉板子座標 raw(夾在 ±max_raw)並記錄時間"""
        clamp = lambda v: max(-self.max_raw, min(self.max_raw, v))
        self.target = (
            clamp(msg.linear.y * self.linear_scale * self.x_sign),   # 板子 X = 左右平移
            clamp(msg.linear.x * self.linear_scale * self.y_sign),   # 板子 Y = 前後
            clamp(msg.angular.z * self.angular_scale * self.z_sign), # 板子 Z = 旋轉
        )
        self.cmd_twist = (msg.linear.x, msg.linear.y, msg.angular.z)
        self.last_cmd_time = self.get_clock().now()
        if self.timed_out:
            self.timed_out = False
            self.get_logger().info("恢復收到 /cmd_vel")

    def tick(self):
        """定時送出速度幀;逾時自動停車;必要時做開環里程計"""
        elapsed = (self.get_clock().now() - self.last_cmd_time).nanoseconds / 1e9
        if elapsed > self.cmd_timeout:
            if not self.timed_out:
                self.timed_out = True
                self.get_logger().warning(
                    f"{self.cmd_timeout}s 未收到 /cmd_vel,自動停車")
            self.bot.stop()
        else:
            self.bot.send_velocity(*self.target)

        # 開環備援:編碼器沒在供資料時,用「實際送出的指令速度」積分
        if (self.publish_odom and self.open_loop_fallback
                and not self.encoder_active):
            vx, vy, wz = (0.0, 0.0, 0.0) if self.timed_out else self.cmd_twist
            self.integrate_and_publish(vx, vy, wz, dt=0.05)

    # ------------------------------------------------------------------
    # 編碼器 → /odom(三全向輪正運動學)
    # ------------------------------------------------------------------

    def make_kinematics(self):
        """預先算好「輪速 → 車體速度」的 3x3 反矩陣。

        輪面線速度模型:v_i = -sin(θi)·vx + cos(θi)·vy + R·ω
        """
        import numpy as np
        m = np.array([[-math.sin(a), math.cos(a), self.robot_radius]
                      for a in self.wheel_angles])
        return np.linalg.pinv(m)

    def on_encoder(self, values):
        """收到一筆編碼器幀:解車體速度並積分位姿(在串列讀取執行緒呼叫)"""
        import numpy as np
        now = self.get_clock().now()
        self.encoder_active = True   # 之後 tick() 不再做開環備援
        if self.last_enc_time is None:
            self.last_enc_time = now
            return
        dt = (now - self.last_enc_time).nanoseconds / 1e9
        self.last_enc_time = now
        if dt <= 0 or dt > 1.0 or len(values) < 3:
            return
        # 取「實際」值(每組第二個),換算輪面線速度 m/s
        wheel_v = np.array([v[1] * self.encoder_scale for v in values[:3]])
        vx, vy, wz = (float(v) for v in self.kinematics @ wheel_v)
        self.integrate_and_publish(vx, vy, wz, dt)

    def integrate_and_publish(self, vx, vy, wz, dt):
        """位姿積分並發布 /odom 與 odom→base_link TF"""
        th = self.pose[2]
        self.pose[0] += (vx * math.cos(th) - vy * math.sin(th)) * dt
        self.pose[1] += (vx * math.sin(th) + vy * math.cos(th)) * dt
        self.pose[2] += wz * dt
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
        odom.twist.twist.linear.x = vx
        odom.twist.twist.linear.y = vy
        odom.twist.twist.angular.z = wz
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
        # 關閉前確保停車
        try:
            self.bot.close()
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
