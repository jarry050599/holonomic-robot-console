import SwiftUI

/// App 進入點
/// 注意:檔名不能叫 main.swift,否則 @main 會與「頂層程式碼」規則衝突
@main
struct RobotConsoleApp: App {
    @StateObject private var model = AppModel()

    init() {
        // SPM 執行檔沒有 bundle 圖示,啟動時設定程式繪製的 Dock 圖示
        NSApplication.shared.applicationIconImage = AppIcon.make()
    }

    var body: some Scene {
        WindowGroup("機器人控制台") {
            RootView(ros: model.ros,
                     teleop: model.teleop,
                     lidar: model.lidar,
                     version: readVersion())
        }
    }
}

/// 組合所有模型物件並接好 ROS topic 線路
@MainActor
final class AppModel: ObservableObject {
    let ros = RosBridgeClient()
    let teleop: TeleopController
    let lidar: LidarModel

    init() {
        let lidar = LidarModel()
        self.lidar = lidar
        self.teleop = TeleopController(ros: ros)

        // /cmd_vel:遙控發布(連線成功時 client 會自動補送 advertise)
        ros.advertise(topic: "/cmd_vel", type: "geometry_msgs/msg/Twist")

        // /scan:雷射訂閱,throttle 100 ms ≈ 10 Hz、只留最新一筆,避免 UI 塞車
        ros.subscribe(topic: "/scan", type: "sensor_msgs/msg/LaserScan",
                      throttleMs: 100) { (scan: LaserScan) in
            lidar.update(with: scan)
        }

        // 啟動鍵盤監聽與 15 Hz 發布迴圈
        teleop.start()

        // 測試掛鉤:設 ROS_AUTOCONNECT=1 時啟動即自動連線(可用 ROS_HOST/ROS_PORT 覆寫)
        let env = ProcessInfo.processInfo.environment
        if env["ROS_AUTOCONNECT"] == "1" {
            let host = env["ROS_HOST"] ?? UserDefaults.standard.string(forKey: "rosbridge.host") ?? "rpi5.local"
            let port = Int(env["ROS_PORT"] ?? "") ?? 9090
            ros.connect(host: host, port: port)
        }
    }
}

/// 讀取打包進 Resources 的版本號
func readVersion() -> String {
    if let url = Bundle.module.url(forResource: "VERSION", withExtension: nil),
       let s = try? String(contentsOf: url) {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "0.0.0"
}
