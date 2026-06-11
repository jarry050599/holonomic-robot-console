#!/usr/bin/env python3
# coding=utf-8
"""Ominibot HV ROS 2 驅動節點。

訂閱 /cmd_vel(geometry_msgs/Twist)→ 換算 raw 速度 → 串列指令寫底盤。
安全機制:
  - 0.5 秒(可調)沒收到 /cmd_vel 自動停車(watchdog)
  - 以固定 20 Hz 重發目前速度,逾時後重發零速度
  - 節點關閉時送停車指令
另把電池訊框轉發為 /battery_voltage(std_msgs/Float32)。
"""
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist
from std_msgs.msg import Float32

from .ominibot_protocol import OminibotProtocol


class OminibotNode(Node):

    def __init__(self):
        super().__init__("ominibot_node")
        # 參數(scale 為 raw 值對 m/s、rad/s 的比例,需實測校正)
        self.declare_parameter("port", "/dev/ominibot")
        self.declare_parameter("baud", 115200)
        self.declare_parameter("linear_scale", 3000.0)    # raw per m/s
        self.declare_parameter("angular_scale", 1500.0)   # raw per rad/s
        self.declare_parameter("cmd_timeout", 0.5)        # 秒;watchdog
        self.declare_parameter("battery_scale", 0.01)     # raw → V(推測 0.01V/格)

        port = self.get_parameter("port").value
        baud = self.get_parameter("baud").value
        self.linear_scale = self.get_parameter("linear_scale").value
        self.angular_scale = self.get_parameter("angular_scale").value
        self.cmd_timeout = self.get_parameter("cmd_timeout").value
        self.battery_scale = self.get_parameter("battery_scale").value

        self.get_logger().info(f"開啟 Ominibot 串列埠 {port} (baud {baud})")
        self.bot = OminibotProtocol(port, baud)

        # 目前目標速度(raw)與最後收到指令的時間
        self.target = (0, 0, 0)
        self.last_cmd_time = self.get_clock().now()
        self.timed_out = False

        self.create_subscription(Twist, "/cmd_vel", self.on_cmd_vel, 10)
        self.battery_pub = self.create_publisher(Float32, "/battery_voltage", 10)

        # 20 Hz 重發目前速度(逾時則發零),兼作 watchdog
        self.create_timer(0.05, self.tick)

        # 背景解析電池訊框
        self.bot.start_reader(on_battery=self.on_battery)

    def on_cmd_vel(self, msg: Twist):
        """收到速度指令:換算成 raw 並記錄時間"""
        self.target = (
            msg.linear.x * self.linear_scale,
            msg.linear.y * self.linear_scale,
            msg.angular.z * self.angular_scale,
        )
        self.last_cmd_time = self.get_clock().now()
        if self.timed_out:
            self.timed_out = False
            self.get_logger().info("恢復收到 /cmd_vel")

    def tick(self):
        """定時送出速度;逾時自動停車"""
        elapsed = (self.get_clock().now() - self.last_cmd_time).nanoseconds / 1e9
        if elapsed > self.cmd_timeout:
            if not self.timed_out:
                self.timed_out = True
                self.get_logger().warning(
                    f"{self.cmd_timeout}s 未收到 /cmd_vel,自動停車")
            self.bot.stop()
            return
        self.bot.send_velocity(*self.target)

    def on_battery(self, voltage_raw, power_raw):
        msg = Float32()
        msg.data = float(voltage_raw) * self.battery_scale
        self.battery_pub.publish(msg)

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
