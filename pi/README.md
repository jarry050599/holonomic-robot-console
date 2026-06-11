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

## Ominibot HV 協定驗證(啟用驅動前必做)

協定來自 iCShop 官方 [ROSKY repo](https://github.com/CIRCUSPi/ROSKY) 的
`ominibot_car_com.py`,但 HV 板韌體可能有差異,先架高機器人(輪子離地)測試:

```bash
# 監聽板子的自動回報(電池/IMU/編碼器),確認有資料
python3 ~/ros2_ws/src/ominibot_driver/ominibot_driver/ominibot_protocol.py \
    --port /dev/ominibot --listen 5

# 小速度測各軸(值是韌體 raw 單位;從小開始!)
python3 ... --vx 300 --duration 1    # 預期:前進
python3 ... --vy 300 --duration 1    # 預期:左平移
python3 ... --vz 300 --duration 1    # 預期:逆時針旋轉
```

方向不對 → 調 `ominibot_protocol.py` 的方向位元組;完全沒反應 → 板子可能
需要先切系統模式(上游 system_mode bit0:0=omnibot、1=mecanum),此時需要
參考板子實際韌體文件。

## 速度校正

驅動節點參數 `linear_scale`(預設 3000 raw / m/s)、`angular_scale`(預設
1500 raw / rad/s)需實測:下固定 raw 速度量測實際移動速度後,改
`pi/systemd/ominibot.service` 的 `--ros-args` 加上
`-p linear_scale:=實測值` 再重新部署。

## 驗收指令

```bash
ros2 topic hz /scan                  # 雷射 ~10 Hz
ros2 topic echo /cmd_vel             # Mac 按 WASD/QE 應看到對應值、放開歸零
sudo systemctl enable --now ominibot # 協定驗證後啟用底盤
# watchdog:Ctrl-C 停掉 Mac App,0.5 秒內馬達應自動停
```
