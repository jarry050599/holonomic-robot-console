import SwiftUI

/// 機器人操作列:一鍵啟動 Pi 端程式、建圖、存圖、導航(免開終端機)
struct OpsPanel: View {
    @ObservedObject var pi: PiControl
    @AppStorage("rosbridge.host") private var host = "rpi5.local"

    var body: some View {
        HStack(spacing: 8) {
            opButton("啟動機器人", "power", "bringup")
            Divider().frame(height: 16)
            opButton("開始建圖", "map", "slam")
            opButton("存圖", "square.and.arrow.down", "save")
            opButton("停止建圖", "stop.circle", "slam-stop")
            Divider().frame(height: 16)
            opButton("開始導航", "location.north.line", "nav2")
            opButton("停止導航", "stop.circle.fill", "nav2-stop")

            if pi.busy {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            Text(pi.lastMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .disabled(pi.busy)
    }

    private func opButton(_ title: String, _ icon: String, _ cmd: String) -> some View {
        Button {
            Task { await pi.run(cmd, host: host) }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
        }
    }
}
