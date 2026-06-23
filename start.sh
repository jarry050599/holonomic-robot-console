#!/bin/bash
# 一鍵啟動:確保樹莓派端整套程式就緒(雷射 + 底盤 + rosbridge),再開 Mac 控制台
#
# 用法:
#   ./start.sh                # 預設連 rpi5.local
#   ./start.sh 192.168.50.232 # 指定主機
#
# 前置需求:做過一次 ssh-copy-id pi@<主機>(免密碼金鑰登入)
set -e
HOST="${1:-rpi5.local}"
USER="pi"
DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="bash ~/ros2_ws/src/robot_bringup/scripts/robot.sh"

echo "==> 1/4 等待樹莓派 $HOST 上線…"
for i in $(seq 1 30); do
  ping -c 1 -t 2 "$HOST" >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { echo "✗ 連不到 $HOST,請確認電源與網路"; exit 1; }
  sleep 2
done
echo "   ✓ $HOST 已上線"

echo "==> 2/4 啟動樹莓派端整套程式(雷射 + 底盤 + rosbridge)…"
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$USER@$HOST" "$REMOTE bringup" 2>&1; then
  echo "✗ ssh 失敗。請先做過 ssh-copy-id $USER@$HOST(免密碼登入)"
  exit 1
fi

echo "==> 3/4 等待 rosbridge(9090)就緒…"
for i in $(seq 1 20); do
  if ssh -o BatchMode=yes "$USER@$HOST" 'ss -ltn | grep -q :9090' 2>/dev/null; then
    echo "   ✓ rosbridge 已就緒"; READY=1; break
  fi
  sleep 1
done
[ -z "$READY" ] && echo "   ⚠ 9090 尚未就緒,App 仍會嘗試連線"

echo "==> 4/4 開啟 Mac 控制台(首次會先編譯)…"
cd "$DIR"
# 把預設連線主機帶給 App,啟動即自動連線
export ROS_AUTOCONNECT=1
export ROS_HOST="$HOST"
export ROS_PORT=9090
exec swift run
