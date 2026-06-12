import SwiftUI

/// 主畫面:連線列 + 操作列;左側遙控,右側「雷射/地圖」分頁
struct RootView: View {
    @ObservedObject var ros: RosBridgeClient
    @ObservedObject var teleop: TeleopController
    @ObservedObject var lidar: LidarModel
    @ObservedObject var map: MapModel
    @ObservedObject var pi: PiControl
    let version: String
    /// 點地圖發導航目標(AppModel 處理發布)
    let onGoal: (Double, Double) -> Void

    @State private var rightTab = 0   // 0 = 雷射, 1 = 地圖
    @AppStorage("autoStartPi") private var autoStartPi = true
    @AppStorage("rosbridge.host") private var host = "rpi5.local"
    @AppStorage("rosbridge.port") private var port = 9090

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBar(ros: ros, version: version)
            OpsPanel(pi: pi)
            Divider()
            HStack(spacing: 0) {
                TeleopPanel(teleop: teleop, ros: ros)
                Divider()
                rightPane
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        // 急停時全視窗紅色邊框提醒
        .overlay(
            Rectangle()
                .stroke(teleop.eStopActive ? Color.red : Color.clear, lineWidth: 6)
                .allowsHitTesting(false)
        )
        .onAppear { autoStart() }
    }

    private var rightPane: some View {
        VStack(spacing: 6) {
            Picker("", selection: $rightTab) {
                Text("雷射").tag(0)
                Text("地圖").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(.top, 8)

            if rightTab == 0 {
                LidarView(lidar: lidar)
            } else {
                MapView(map: map, onGoal: onGoal)
            }
        }
        // 收到地圖時自動切到地圖分頁(建圖開始的回饋)
        .onChange(of: map.hasMap) { has in
            if has { rightTab = 1 }
        }
    }

    /// App 開啟時自動帶起 Pi 端 bringup 並連線(可用 autoStartPi 關閉)
    private func autoStart() {
        guard autoStartPi, ros.state == .disconnected else { return }
        Task {
            await pi.run("bringup", host: host)
            // 給 rosbridge 一點啟動時間再連(已在跑則立即成功)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if ros.state == .disconnected {
                ros.connect(host: host, port: port)
            }
        }
    }
}
