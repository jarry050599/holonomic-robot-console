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

1. **開 App 自動啟動**:App 會自動 ssh 到樹莓派帶起整套程式(rosbridge +
   雷射 + 底盤,冪等不重複開)並自動連線。前置需求:做過一次
   `ssh-copy-id pi@rpi5.local`。也可手動按操作列「啟動機器人」。
2. 遙控:`W/S` 前後、`A/D` 左右平移、`Q/E` 旋轉;放開立即歸零。
   **空白鍵 = 急停**(閂鎖,持續發零速度;再按一次或點按鈕解除)。
   點過輸入框後,點一下遙控面板即可取回鍵盤控制。
3. 右側「雷射」分頁:`/scan` 點雲(濾噪、直線擬合可開關、可錄放);
   最近障礙物 < 0.3 m 時面板變紅警示。
4. **建圖**:按「開始建圖」→ 遙控繞房間,「地圖」分頁即時顯示 `/map`
   成形過程(收到第一張圖自動切換)→ 按「存圖」。
5. **導航**:按「開始導航」→ **在地圖上點一下 = 發送導航目標**(紅圈
   標記),機器人自己走過去;藍色箭頭 = 機器人位置與朝向。
6. 速度上限滑桿:線速度 0~0.5 m/s、角速度 0~1.5 rad/s;連線設定自動記憶。

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
