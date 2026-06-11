import SwiftUI

/// 連線列:host/port 輸入、連線/斷線按鈕、狀態指示燈
struct ConnectionBar: View {
    @ObservedObject var ros: RosBridgeClient
    let version: String

    // 連線設定記憶(M3-6):存 UserDefaults
    @AppStorage("rosbridge.host") private var host = "rpi5.local"
    @AppStorage("rosbridge.port") private var port = 9090

    var body: some View {
        HStack(spacing: 12) {
            statusLight
            TextField("主機", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            TextField("埠", value: $port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)

            Button(action: toggleConnection) {
                Text(buttonTitle).frame(width: 56)
            }
            .keyboardShortcut(.return, modifiers: .command)

            if let error = ros.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            Spacer()
            Text("v\(version)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
    }

    private var buttonTitle: String {
        switch ros.state {
        case .disconnected: return "連線"
        case .connecting:   return "取消"
        case .connected:    return "斷線"
        }
    }

    private func toggleConnection() {
        switch ros.state {
        case .disconnected:
            ros.connect(host: host, port: port)
        case .connecting, .connected:
            ros.disconnect()
        }
    }

    /// 狀態指示燈:灰=未連線、橘=連線中、綠=已連線
    private var statusLight: some View {
        Circle()
            .fill(lightColor)
            .frame(width: 12, height: 12)
            .help(lightHelp)
    }

    private var lightColor: Color {
        switch ros.state {
        case .disconnected: return .gray
        case .connecting:   return .orange
        case .connected:    return .green
        }
    }

    private var lightHelp: String {
        switch ros.state {
        case .disconnected: return "未連線"
        case .connecting:   return "連線中…"
        case .connected:    return "已連線"
        }
    }
}
