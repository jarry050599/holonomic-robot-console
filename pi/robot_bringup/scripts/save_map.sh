#!/bin/bash
# 存地圖:PGM+YAML(Nav2 用)與 slam_toolbox 序列化檔(之後可續建/重定位)
# 用法:./save_map.sh [名稱]   (預設 map_時間戳;存到 ~/maps/)
set -e
NAME="${1:-map_$(date +%Y%m%d_%H%M%S)}"
mkdir -p ~/maps
source /opt/ros/jazzy/setup.bash

ros2 run nav2_map_server map_saver_cli -f ~/maps/"$NAME" --ros-args -p save_map_timeout:=10.0
ros2 service call /slam_toolbox/serialize_map slam_toolbox/srv/SerializePoseGraph \
    "{filename: '$HOME/maps/$NAME'}" > /dev/null || echo "(序列化失敗,僅存 PGM/YAML)"

echo "已存:~/maps/$NAME.pgm / .yaml(Nav2 地圖)與 .posegraph/.data(slam_toolbox)"
echo "Nav2 使用:ros2 launch robot_bringup nav2.launch.py map:=\$HOME/maps/$NAME.yaml"
