# 萬向輪機器人控制台

原生 macOS SwiftUI App(Swift Package,免 Xcode 專案):遙控萬向輪機器人底盤、
即時顯示雷射點雲。透過 rosbridge WebSocket(JSON)與樹莓派上的 ROS 2 Jazzy 溝通。

```
Mac (SwiftUI App) ── WebSocket(rosbridge, 9090)──▶ 樹莓派 rpi5.local
                                                    ├─ sllidar_ros2 → /scan
                                                    └─ ominibot_driver ← /cmd_vel
```

## 快速上手

```bash
swift run     # macOS 12+、Swift 5.7+
```

1. 連線列輸入主機(預設 `rpi5.local`)與埠(預設 `9090`),按「連線」。
2. 遙控:`W/S` 前後、`A/D` 左右平移、`Q/E` 旋轉;放開立即歸零。
   **空白鍵 = 急停**(閂鎖,持續發零速度;再按一次或點按鈕解除)。
3. 右側即時顯示 `/scan` 點雲(機器人置中、距離圈 1/2/4 m);
   最近障礙物 < 0.3 m 時面板變紅警示。
4. 速度上限滑桿:線速度 0~0.5 m/s、角速度 0~1.5 rad/s。
5. 雷射可錄製/回放;連線設定自動記憶。

測試掛鉤:`ROS_AUTOCONNECT=1 ROS_HOST=… ROS_PORT=… swift run` 啟動即自動連線。

## 程式結構

| 路徑 | 說明 |
|---|---|
| `Sources/App/RobotConsoleApp.swift` | 進入點與物件組裝(topic 接線) |
| `Sources/App/RosBridge/` | rosbridge WebSocket 客戶端與 ROS 訊息型別 |
| `Sources/App/Teleop/` | 遙控:鍵盤監聽、15 Hz 連續發布、急停 |
| `Sources/App/Lidar/` | LaserScan → 點雲轉換、頻率/最近距離統計、錄放 |
| `Sources/App/Views/` | 連線列、遙控面板、雷射視圖 |
| `pi/` | 樹莓派端:ominibot 驅動套件、udev、systemd、部署腳本(見 [pi/README.md](pi/README.md)) |

## 樹莓派端部署

```bash
ssh-copy-id pi@rpi5.local   # 一次性
./pi/deploy.sh              # 安裝 rosbridge、udev 別名、systemd 自啟、編譯驅動
```

底盤馬達啟用前務必先做協定硬體驗證(機器人架高),詳見 [pi/README.md](pi/README.md)。

## 離線測試(不需樹莓派)

```bash
python3 tools/mock_rosbridge.py &                      # 假 rosbridge:模擬 /scan、記錄 /cmd_vel
ROS_AUTOCONNECT=1 ROS_HOST=127.0.0.1 swift run         # 連 127.0.0.1:9090
tail -f /tmp/mock_rosbridge.log                        # 觀察收到的 cmd_vel
```
