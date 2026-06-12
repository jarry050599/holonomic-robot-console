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

## OminiBot HV v1.2 協定(2026-06-12 實機驗證可動)

⚠ **GitHub iCShopMgr/OminiBotHV 的 2020 PDF(FF FE 幀頭)是舊韌體,對本板無效!**
本板用「大括號協定」:`0x7B + cmd + 資料 + BCC(XOR) + 0x7D`,固定 14 bytes。
權威參考:[reference/OminiBot_HV_Meca.py](ominibot_driver/reference/OminiBot_HV_Meca.py)
(出土自舊 SD 卡);本驅動的幀格式與其位元組級一致。

- `0x25` 整車速度:**單位直接是 m/s、rad/s(×1000 有號 16-bit),不需 raw 標定**
- 板子主動串流 24 Hz 遙測:實測車速 + IMU 四元數 + 電池(mV)→ 驅動直接
  發布 `/odom`(速度積分 + IMU yaw)、TF 與 `/battery_voltage`
- 板子電源開關在 XT60 旁;OFF 時 FTDI 仍會列舉(吃 USB 電),USB 有裝置≠板子活著

測試工具(輪子先架空!):

```bash
T=~/ros2_ws/src/ominibot_driver/ominibot_driver/ominibot_protocol.py
python3 $T --port /dev/ominibot --read 4               # 讀遙測(被動,安全)
python3 $T --port /dev/ominibot --x 0.08 --duration 1  # 前進 0.08 m/s
```

## 驅動節點參數

| 參數 | 預設 | 說明 |
|---|---|---|
| `max_linear` / `max_angular` | 0.5 / 1.5 | 速度上限(m/s、rad/s) |
| `x_sign` `y_sign` `z_sign` | 1.0 | 軸向正負號(實測相反就改 -1) |
| `wheel_diameter` `wheel_space` `axle_space` | 60 / 110 / 110 | mm,0x24 車體設定 |
| `gear_ratio` / `encoder_ppr` | 55 / 165 | 0x23 系統設定 |
| `use_imu_yaw` | true | /odom 的 yaw 用 IMU 四元數(否則積分 wz) |
| `battery_scale` | 0.001 | 電池 raw(mV)→ V |

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
