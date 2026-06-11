"""導航:Nav2(AMCL 定位 + MPPI 全向輪控制;bringup 須先在跑)

用法:
    ros2 launch robot_bringup nav2.launch.py map:=$HOME/maps/map.yaml
下目標點(rviz 或指令):
    ros2 topic pub --once /goal_pose geometry_msgs/PoseStamped \
        "{header: {frame_id: map}, pose: {position: {x: 1.0, y: 0.5}, orientation: {w: 1.0}}}"
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    share = get_package_share_directory("robot_bringup")
    nav2_launch = os.path.join(
        get_package_share_directory("nav2_bringup"), "launch", "bringup_launch.py")

    return LaunchDescription([
        DeclareLaunchArgument("map", description="地圖 yaml 路徑(save_map.sh 的輸出)"),
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(nav2_launch),
            launch_arguments={
                "map": LaunchConfiguration("map"),
                "params_file": os.path.join(share, "config", "nav2_params.yaml"),
                "use_sim_time": "false",
            }.items(),
        ),
    ])
