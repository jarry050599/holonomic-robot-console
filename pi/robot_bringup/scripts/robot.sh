#!/bin/bash
# 機器人統一控制腳本(Mac App 透過 ssh 呼叫;手動使用亦可)
# 用法:robot.sh bringup|slam|save [名稱]|slam-stop|nav2 [名稱]|nav2-stop|status
# 注意:不可用 set -u,ROS 的 setup.bash 內含未定義變數
source /opt/ros/jazzy/setup.bash
source ~/ros2_ws/install/setup.bash 2>/dev/null

start_detached() {  # $1=識別 pattern $2=log $3...=指令
    local pat="$1" log="$2"; shift 2
    if pgrep -f "$pat" > /dev/null; then
        echo "已在跑"
    else
        setsid nohup "$@" > "$log" 2>&1 < /dev/null &
        echo "啟動中(log: $log)"
    fi
}

case "${1:-status}" in
  bringup)
    start_detached "bringup[.]launch" /tmp/bringup.log \
        ros2 launch robot_bringup bringup.launch.py ;;
  slam)
    dpkg -l ros-jazzy-slam-toolbox 2>/dev/null | grep -q ^ii \
        || { echo "錯誤:slam_toolbox 未安裝,請先跑 deploy.sh"; exit 1; }
    start_detached "slam[.]launch" /tmp/slam.log \
        ros2 launch robot_bringup slam.launch.py ;;
  save)
    bash ~/ros2_ws/src/robot_bringup/scripts/save_map.sh "${2:-app_map}" ;;
  slam-stop)
    pkill -f "slam[.]launch" && echo "已停止建圖" || echo "建圖不在跑" ;;
  nav2)
    dpkg -l ros-jazzy-nav2-bringup 2>/dev/null | grep -q ^ii \
        || { echo "錯誤:nav2 未安裝,請先跑 deploy.sh"; exit 1; }
    NAME="${2:-app_map}"
    [ -f "$HOME/maps/$NAME.yaml" ] || { echo "錯誤:找不到地圖 ~/maps/$NAME.yaml,請先建圖存圖"; exit 1; }
    start_detached "nav2[.]launch" /tmp/nav2.log \
        ros2 launch robot_bringup nav2.launch.py map:="$HOME/maps/$NAME.yaml" ;;
  nav2-stop)
    pkill -f "nav2[.]launch" && echo "已停止導航" || echo "導航不在跑" ;;
  status)
    for item in "bringup[.]launch:bringup" "slam[.]launch:建圖" "nav2[.]launch:導航"; do
        pat="${item%%:*}"; name="${item##*:}"
        pgrep -f "$pat" > /dev/null && echo "$name: 跑著" || echo "$name: 停止"
    done ;;
  *)
    echo "未知指令:$1"; exit 1 ;;
esac
