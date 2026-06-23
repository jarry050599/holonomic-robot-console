"""整機啟動:雷射 + 底盤驅動 + static TF(base_link→laser)+ rosbridge

用法:
    ros2 launch robot_bringup bringup.launch.py
    ros2 launch robot_bringup bringup.launch.py ominibot_port:=/dev/ttyUSB1
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (DeclareLaunchArgument, ExecuteProcess,
                            IncludeLaunchDescription, TimerAction)
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    lidar_port = LaunchConfiguration("lidar_port")
    ominibot_port = LaunchConfiguration("ominibot_port")
    laser_x = LaunchConfiguration("laser_x")
    laser_z = LaunchConfiguration("laser_z")
    laser_yaw = LaunchConfiguration("laser_yaw")
    scan_frequency = LaunchConfiguration("scan_frequency")

    rosbridge_launch = os.path.join(
        get_package_share_directory("rosbridge_server"),
        "launch", "rosbridge_websocket_launch.xml")

    return LaunchDescription([
        DeclareLaunchArgument("lidar_port", default_value="/dev/rplidar"),
        DeclareLaunchArgument("ominibot_port", default_value="/dev/ominibot"),
        # 雷射相對 base_link 的安裝位置(依實車量測調整)
        DeclareLaunchArgument("laser_x", default_value="0.0"),
        DeclareLaunchArgument("laser_z", default_value="0.10"),
        DeclareLaunchArgument("laser_yaw", default_value="0.0"),
        # 雷射掃描頻率(僅影響每圈點數;實測無法改 A2M12 馬達轉速,維持預設 10)
        DeclareLaunchArgument("scan_frequency", default_value="10.0"),

        # RPLIDAR A2M12(⚠ 串列埠務必用短路徑,SDK 有埠名長度 bug)
        # 註:此顆 A2M12 馬達轉速無法調慢(下達較低 motor_pwm 會 OPERATION_TIMEOUT),
        #     僅能以預設 ~10Hz 運作
        Node(
            package="sllidar_ros2", executable="sllidar_node",
            name="sllidar_node", output="screen",
            parameters=[{
                "serial_port": lidar_port,
                "serial_baudrate": 256000,
                "frame_id": "laser",
                "scan_frequency": ParameterValue(scan_frequency, value_type=float),
            }],
        ),

        # Ominibot HV 底盤驅動(/cmd_vel → 馬達;/odom + odom→base_link TF)
        Node(
            package="ominibot_driver", executable="ominibot_node",
            name="ominibot_node", output="screen",
            parameters=[{"port": ominibot_port}],
        ),

        # base_link → laser 靜態轉換
        Node(
            package="tf2_ros", executable="static_transform_publisher",
            name="base_to_laser_tf",
            arguments=["--x", laser_x, "--y", "0", "--z", laser_z,
                       "--yaw", laser_yaw, "--pitch", "0", "--roll", "0",
                       "--frame-id", "base_link", "--child-frame-id", "laser"],
        ),

        # rosbridge WebSocket(9090,Mac App 連這裡)
        IncludeLaunchDescription(AnyLaunchDescriptionSource(rosbridge_launch)),

        # 保險:有時開機後雷射馬達不會自動啟轉,延遲 10 秒補一次
        # start_motor(已在轉動時呼叫無副作用)
        TimerAction(period=10.0, actions=[
            ExecuteProcess(cmd=["ros2", "service", "call", "/start_motor",
                                "std_srvs/srv/Empty"], output="log"),
        ]),
    ])
