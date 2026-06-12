"""SLAM:slam_toolbox 非同步建圖(bringup 須先在跑)

slam_toolbox 是 lifecycle node,須走官方 launch 的 configure/activate 流程,
這裡 include 官方 online_async_launch.py 並帶入本套件的參數檔。

用法:
    ros2 launch robot_bringup slam.launch.py
建圖時用 Mac App 遙控繞房間,完成後執行 scripts/save_map.sh 存圖。
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource


def generate_launch_description():
    params = os.path.join(
        get_package_share_directory("robot_bringup"), "config", "slam_params.yaml")
    slam_launch = os.path.join(
        get_package_share_directory("slam_toolbox"), "launch", "online_async_launch.py")

    return LaunchDescription([
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(slam_launch),
            launch_arguments={
                "slam_params_file": params,
                "use_sim_time": "false",
            }.items(),
        ),
    ])
