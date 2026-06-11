import SwiftUI

/// 主畫面:上方連線列,左側遙控面板,右側雷射點雲
struct RootView: View {
    @ObservedObject var ros: RosBridgeClient
    @ObservedObject var teleop: TeleopController
    @ObservedObject var lidar: LidarModel
    let version: String

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBar(ros: ros, version: version)
            Divider()
            HStack(spacing: 0) {
                TeleopPanel(teleop: teleop, ros: ros)
                Divider()
                LidarView(lidar: lidar)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        // 急停時全視窗紅色邊框提醒
        .overlay(
            Rectangle()
                .stroke(teleop.eStopActive ? Color.red : Color.clear, lineWidth: 6)
                .allowsHitTesting(false)
        )
    }
}
