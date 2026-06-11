#!/bin/bash
# 樹莓派一鍵部署:從 Mac 執行 ./pi/deploy.sh [pi@rpi5.local]
# 需要可 ssh 到樹莓派(建議先 ssh-copy-id);sudo 密碼會在終端機提示輸入。
set -euo pipefail

PI="${1:-pi@rpi5.local}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 1/5 複製檔案到 $PI ==="
ssh "$PI" 'mkdir -p ~/ros2_ws/src /tmp/robot-deploy'
scp -r "$DIR/ominibot_driver" "$DIR/robot_bringup" "$PI:~/ros2_ws/src/"
scp "$DIR/udev/99-robot.rules" "$DIR"/systemd/*.service "$PI:/tmp/robot-deploy/"

echo "=== 2/5 安裝套件、udev 規則(需要 sudo 密碼) ==="
ssh -t "$PI" '
set -e
sudo apt-get update
sudo apt-get install -y ros-jazzy-rosbridge-suite python3-serial \
    ros-jazzy-slam-toolbox ros-jazzy-navigation2 ros-jazzy-nav2-bringup

# udev:若已有 99-robot.rules 先備份再覆蓋
if [ -f /etc/udev/rules.d/99-robot.rules ]; then
    echo "--- 既有 99-robot.rules 與新版差異:"
    diff /etc/udev/rules.d/99-robot.rules /tmp/robot-deploy/99-robot.rules || true
    sudo cp /etc/udev/rules.d/99-robot.rules /etc/udev/rules.d/99-robot.rules.bak
fi
sudo cp /tmp/robot-deploy/99-robot.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
sleep 1
ls -l /dev/rplidar /dev/ominibot || echo "⚠ 別名未出現,請確認裝置有接上"
'

echo "=== 3/5 編譯 ominibot_driver + robot_bringup ==="
ssh "$PI" '
set -e
source /opt/ros/jazzy/setup.bash
cd ~/ros2_ws
colcon build --packages-select ominibot_driver robot_bringup --symlink-install
'

echo "=== 4/5 安裝 systemd 服務(rosbridge + sllidar 立即啟用) ==="
ssh -t "$PI" '
set -e
sudo cp /tmp/robot-deploy/rosbridge.service /tmp/robot-deploy/sllidar.service /tmp/robot-deploy/ominibot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rosbridge.service sllidar.service
# ominibot.service 先安裝不啟用:協定通過硬體驗證後再 sudo systemctl enable --now ominibot
sleep 3
systemctl --no-pager --lines 0 status rosbridge.service sllidar.service || true
'

echo "=== 5/5 驗證 ==="
ssh "$PI" '
source /opt/ros/jazzy/setup.bash
timeout 8 ros2 topic hz /scan --window 20 2>/dev/null | head -2 || echo "⚠ /scan 尚未發布,檢查 sllidar.service 日誌:journalctl -u sllidar"
ss -ltn | grep -q ":9090" && echo "✓ rosbridge 在 9090 聆聽" || echo "⚠ rosbridge 未聆聽 9090"
'

echo "完成。下一步:硬體驗證底盤協定(把機器人架高!):"
echo "  ssh $PI 'python3 ~/ros2_ws/src/ominibot_driver/ominibot_driver/ominibot_protocol.py --port /dev/ominibot --vx 300 --duration 1'"
echo "通過後啟用驅動:ssh -t $PI 'sudo systemctl enable --now ominibot.service'"
