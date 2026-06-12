import SwiftUI

/// App 進入點
/// 注意:檔名不能叫 main.swift,否則 @main 會與「頂層程式碼」規則衝突
/// 無 bundle 的 SPM 執行檔預設會被當成背景程式(沒視窗、沒 Dock 圖示),
/// 啟動完成時明確設成前景程式並掛上程式繪製的圖示。
/// 注意:不能在 App.init() 提早碰 NSApplication.shared,會搶在 SwiftUI
/// 設定活化政策之前建立 app 實例,導致視窗永遠不出現。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.make()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RobotConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("機器人控制台") {
            RootView(ros: model.ros,
                     teleop: model.teleop,
                     lidar: model.lidar,
                     map: model.map,
                     pi: model.pi,
                     version: readVersion(),
                     onGoal: model.sendGoal)
        }
    }
}

/// 組合所有模型物件並接好 ROS topic 線路
@MainActor
final class AppModel: ObservableObject {
    let ros = RosBridgeClient()
    let teleop: TeleopController
    let lidar: LidarModel
    let map = MapModel()
    let pi = PiControl()

    init() {
        let lidar = LidarModel()
        self.lidar = lidar
        self.teleop = TeleopController(ros: ros)
        let map = self.map

        // /cmd_vel:遙控發布(連線成功時 client 會自動補送 advertise)
        ros.advertise(topic: "/cmd_vel", type: "geometry_msgs/msg/Twist")
        // /goal_pose:點地圖導航目標
        ros.advertise(topic: "/goal_pose", type: "geometry_msgs/msg/PoseStamped")

        // /scan:雷射訂閱,throttle 100 ms ≈ 10 Hz、只留最新一筆,避免 UI 塞車
        ros.subscribe(topic: "/scan", type: "sensor_msgs/msg/LaserScan",
                      throttleMs: 100) { (scan: LaserScan) in
            lidar.update(with: scan)
        }

        // /map:SLAM 建圖結果(地圖大、2 秒一張即可)
        ros.subscribe(topic: "/map", type: "nav_msgs/msg/OccupancyGrid",
                      throttleMs: 2000) { (grid: OccupancyGrid) in
            map.update(with: grid)
        }
        // 機器人位姿:建圖時來自 slam_toolbox(/pose)、導航時來自 AMCL(/amcl_pose)
        ros.subscribe(topic: "/pose", type: "geometry_msgs/msg/PoseWithCovarianceStamped",
                      throttleMs: 200) { (pose: PoseWithCovarianceStamped) in
            map.updateRobot(with: pose)
        }
        ros.subscribe(topic: "/amcl_pose", type: "geometry_msgs/msg/PoseWithCovarianceStamped",
                      throttleMs: 200) { (pose: PoseWithCovarianceStamped) in
            map.updateRobot(with: pose)
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

    /// 點地圖 → 發布導航目標(map 座標;朝向先固定朝 +x)
    func sendGoal(x: Double, y: Double) {
        var pose = RosPose()
        pose.position.x = x
        pose.position.y = y
        ros.publish(topic: "/goal_pose",
                    msg: PoseStamped(header: RosHeader(frameId: "map"), pose: pose))
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
