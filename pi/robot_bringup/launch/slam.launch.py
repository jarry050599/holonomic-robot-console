"""SLAM:slam_toolbox 非同步建圖(bringup 須先在跑)

用法:
    ros2 launch robot_bringup slam.launch.py
建圖時用 Mac App 遙控繞房間,完成後執行 scripts/save_map.sh 存圖。
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    params = os.path.join(
        get_package_share_directory("robot_bringup"), "config", "slam_params.yaml")

    return LaunchDescription([
        Node(
            package="slam_toolbox", executable="async_slam_toolbox_node",
            name="slam_toolbox", output="screen",
            parameters=[params],
        ),
    ])
