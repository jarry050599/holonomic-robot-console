# 樹莓派端設定(rpi5.local)

Mac App 的對向端:rosbridge(9090)+ RPLIDAR `/scan` + Ominibot HV 底盤 `/cmd_vel`。

## 部署

```bash
# 一次性:設定免密碼 SSH(會要求輸入 pi 的密碼)
ssh-copy-id pi@rpi5.local

# 一鍵部署(sudo 密碼會在過程中提示)
./pi/deploy.sh
```

部署內容:

| 項目 | 說明 |
|---|---|
| `ros-jazzy-rosbridge-suite` | apt 安裝,WebSocket 9090 |
| `udev/99-robot.rules` | 固定短別名 `/dev/rplidar`(CP2102)、`/dev/ominibot`(FTDI 序號 D34V3T9O);若 Pi 上已有同名規則會先備份成 `.bak` 再覆蓋 |
| `ominibot_driver/` | ROS 2 套件,複製到 `~/ros2_ws/src/` 後 colcon build |
| `systemd/*.service` | 開機自啟;`rosbridge`、`sllidar` 立即啟用,`ominibot` 待硬體驗證後手動啟用 |

## OminiBot HV 協定驗證(啟用驅動前必做)

協定依官方文件 [iCShopMgr/OminiBotHV](https://github.com/iCShopMgr/OminiBotHV)
(三全向輪,UART 115200,板子收到 10 bytes 自動切 UART 控制模式)。
先架高機器人(輪子離地)測試:

```bash
T=~/ros2_ws/src/ominibot_driver/ominibot_driver/ominibot_protocol.py
# 小速度測各軸(板子座標;值是韌體 raw 單位,從小開始!)
python3 $T --port /dev/ominibot --y 200 --duration 1    # 預期:前進(板子 Y 軸=前後)
python3 $T --port /dev/ominibot --x 200 --duration 1    # 預期:平移(板子 X 軸=左右)
python3 $T --port /dev/ominibot --z 200 --duration 1    # 預期:原地旋轉
```

方向相反 → 不用改程式,調驅動節點參數 `x_sign`/`y_sign`/`z_sign`(±1)。

## 標定(驅動節點參數)

| 參數 | 預設 | 說明 |
|---|---|---|
| `linear_scale` | 1000 | raw / (m/s):下固定 raw 速度量實際車速後換算 |
| `angular_scale` | 500 | raw / (rad/s) |
| `x_sign` `y_sign` `z_sign` | 1.0 | 軸向正負號(實測相反就改 -1) |
| `encoder_scale` | 0.001 | 編碼器「實際」raw → 輪面 m/s(/odom 用) |
| `robot_radius` | 0.15 | 輪心到車中心距離 m(/odom 用) |

標定後把參數加進 `pi/systemd/ominibot.service` 的 `--ros-args -p 名稱:=值`
再重新部署。

## 里程計 /odom(選配)

板子 System mode **bit6=1** 時會回傳編碼器幀(`0x24 … 0x19`,每值有號
32-bit),節點會以三全向輪正運動學解出車速並積分發布 `/odom`。
bit6 預設關閉;開啟需用設定幀(Mode 0x80 子命令 0x09)改 System mode 並
寫入存檔,建議照官方 PDF(`OminiBotHV_protocol.pdf`)操作後再驗證:

```bash
python3 $T --port /dev/ominibot --listen 5   # 應看到 encoder: [(目標,實際), ...]
```

## 整機啟動、SLAM 建圖與 Nav2 導航

```bash
# 0. 一次性安裝(需 sudo;deploy.sh 也會裝)
sudo apt install -y ros-jazzy-slam-toolbox ros-jazzy-navigation2 ros-jazzy-nav2-bringup

# 1. 整機啟動:雷射 + 底盤 + base_link→laser TF + rosbridge
ros2 launch robot_bringup bringup.launch.py
#    (udev 別名尚未生效時:ominibot_port:=/dev/serial/by-id/usb-FTDI_OminiBotHV_…)

# 2. SLAM 建圖(另一個終端;用 Mac App 遙控繞房間,/map 漸漸成形)
ros2 launch robot_bringup slam.launch.py
~/ros2_ws/src/robot_bringup/scripts/save_map.sh 我的地圖   # 繞完存圖

# 3. Nav2 導航(先停掉 slam.launch)
ros2 launch robot_bringup nav2.launch.py map:=$HOME/maps/我的地圖.yaml
ros2 topic pub --once /goal_pose geometry_msgs/msg/PoseStamped \
  "{header: {frame_id: map}, pose: {position: {x: 1.0, y: 0.5}, orientation: {w: 1.0}}}"
```

設計重點:
- 驅動會發布 `/odom` 與 odom→base_link TF;**編碼器沒資料時自動退回
  「指令速度開環積分」**,標定前就能先建圖(精度有限,靠 scan matching 補)
- Nav2 控制器用 **MPPI、motion_model: Omni**(允許 y 向平移),AMCL 用
  OmniMotionModel;速度上限對齊驅動的保守值 0.3 m/s / 1.0 rad/s
- 雷射安裝位置用 launch 參數調:`laser_x`/`laser_z`/`laser_yaw`

## 驗收指令

```bash
ros2 topic hz /scan                  # 雷射 ~10 Hz
ros2 topic echo /cmd_vel             # Mac 按 WASD/QE 應看到對應值、放開歸零
sudo systemctl enable --now ominibot # 協定驗證後啟用底盤
# watchdog:Ctrl-C 停掉 Mac App,0.5 秒內馬達應自動停
```
