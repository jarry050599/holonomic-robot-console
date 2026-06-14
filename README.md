# 萬向輪機器人控制台 (Holonomic Robot Console)

> 原生 macOS SwiftUI 控制台 + 樹莓派 ROS 2 Jazzy 後端,用來遙控全向輪
> (OminiBot HV)機器人底盤、即時看雷射點雲、SLAM 建圖、點地圖自動導航。
> 全程用 rosbridge WebSocket(JSON)通訊,Mac 端零外部相依(只用 URLSession)。

授權:Apache-2.0 ｜ 平台:macOS 12+ / Raspberry Pi 5 + Ubuntu 24.04 + ROS 2 Jazzy

```
┌─────────────────────┐        WebSocket            ┌──────────────────────────────┐
│  Mac (SwiftUI App)   │  rosbridge JSON :9090       │  樹莓派 rpi5.local             │
│  遙控 / 雷射 / 地圖   │ ◀──────────────────────────▶ │  ├─ rosbridge_server          │
│  點地圖導航          │   /cmd_vel /scan /map        │  ├─ sllidar_ros2   → /scan    │
└─────────────────────┘   /odom /goal_pose ...       │  ├─ ominibot_driver ↔ 底盤    │
                                                      │  └─ slam_toolbox / Nav2       │
                                                      └──────────────────────────────┘
```

## 功能狀態

| 功能 | 狀態 |
|---|---|
| 鍵盤/虛擬搖桿遙控、急停、速度上限 | ✅ |
| 雷射點雲即時顯示(濾噪、直線擬合、錄放) | ✅ |
| 底盤驅動(OminiBot HV 大括號協定,m/s 直驅) | ✅ 實機驗證 |
| 里程計 `/odom` + TF(輪速 + IMU 偏航) | ✅ |
| 連線停滯偵測(ping 保活、資料逾時警示) | ✅ |
| App 一鍵啟動 Pi、SLAM 建圖、點地圖導航 | ✅ 軟體就緒 |
| **整機穩定建圖/導航** | ⚠ 受限於供電,見下方「已知問題」 |

### ⚠ 已知問題:供電 brownout

實測中,馬達啟動的瞬間電流會把與底盤共用的電池電壓拉低,導致樹莓派斷電
重啟——表現為畫面凍結、地圖飄移/星芒狀、SSH 中斷。**這是硬體供電問題,
非軟體 bug。** 解法:電池充飽、或讓樹莓派獨立供電(5V/5A),不與馬達共用。
軟體端已加上斷線偵測與 0.5 秒失聯自動煞車。

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
python3 tools/mock_rosbridge.py &                      # 假 rosbridge:模擬 /scan、/map、記錄 /cmd_vel
ROS_AUTOCONNECT=1 ROS_HOST=127.0.0.1 swift run         # 連 127.0.0.1:9090
tail -f /tmp/mock_rosbridge.log                        # 觀察收到的 cmd_vel / goal_pose
```

## 硬體

- **Mac**:macOS 12+(Swift 5.7+);App 為 Swift Package,`swift run` 直接跑
- **運算**:Raspberry Pi 5 + Ubuntu 24.04 + ROS 2 Jazzy
- **雷射**:RPLIDAR A2M12(CP2102,256000 baud)
- **底盤**:OminiBot HV v1.2 三全向輪(FTDI,115200,大括號協定 — 見
  [pi/README.md](pi/README.md);GitHub 上 iCShop 的 2020 PDF 為舊韌體,對本板無效)

## 授權與致謝

- 授權:[Apache-2.0](LICENSE)(允許自由使用、修改、散布與商用)
- **商業使用**:Apache-2.0 不強制,但若你將本專案用於商業用途,
  歡迎(非義務)來信告知作者一聲:**jarry050599@gmail.com**
- OminiBot HV 串列協定為自行重寫實作,協定格式參考
  [iCShop / CIRCUSPi OminiBotHV](https://github.com/iCShopMgr/OminiBotHV) 的廠商驅動
- 建圖/導航使用 [slam_toolbox](https://github.com/SteveMacenski/slam_toolbox) 與
  [Nav2](https://github.com/ros-navigation/navigation2)
