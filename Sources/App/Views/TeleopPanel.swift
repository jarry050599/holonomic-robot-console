import SwiftUI

/// 遙控面板:方向按鈕、旋轉按鈕、速度滑桿、急停
struct TeleopPanel: View {
    @ObservedObject var teleop: TeleopController
    @ObservedObject var ros: RosBridgeClient

    var body: some View {
        VStack(spacing: 16) {
            Text("遙控")
                .font(.headline)

            directionPad
            rotationButtons
            sliders
            velocityReadout
            eStopButton
            keyHint
        }
        .padding()
        .frame(width: 280)
        .disabled(ros.state != .connected)
        .opacity(ros.state == .connected ? 1 : 0.5)
    }

    // MARK: - 方向按鈕(全向:含斜向平移)

    private var directionPad: some View {
        // 每列三顆:(x, y) 方向係數;ROS 慣例 y 左為正
        let rows: [[(label: String, x: Double, y: Double)?]] = [
            [("↖", 1, 1), ("↑", 1, 0), ("↗", 1, -1)],
            [("←", 0, 1), nil,         ("→", 0, -1)],
            [("↙", -1, 1), ("↓", -1, 0), ("↘", -1, -1)],
        ]
        return VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { c in
                        if let item = rows[r][c] {
                            HoldButton(label: item.label) {
                                teleop.setButtonAxes(x: item.x, y: item.y, z: 0)
                            } onRelease: {
                                teleop.releaseButtons()
                            }
                        } else {
                            // 中央:目前移動方向的小指示
                            Image(systemName: "dot.circle")
                                .frame(width: 44, height: 44)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var rotationButtons: some View {
        HStack(spacing: 6) {
            HoldButton(label: "⟲ 左旋", width: 71) {
                teleop.setButtonAxes(x: 0, y: 0, z: 1)
            } onRelease: {
                teleop.releaseButtons()
            }
            HoldButton(label: "⟳ 右旋", width: 71) {
                teleop.setButtonAxes(x: 0, y: 0, z: -1)
            } onRelease: {
                teleop.releaseButtons()
            }
        }
    }

    // MARK: - 速度上限滑桿

    private var sliders: some View {
        VStack(spacing: 8) {
            HStack {
                Text("線速度上限")
                    .font(.caption)
                Slider(value: $teleop.maxLinear, in: 0...0.5)
                Text(String(format: "%.2f m/s", teleop.maxLinear))
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
            }
            HStack {
                Text("角速度上限")
                    .font(.caption)
                Slider(value: $teleop.maxAngular, in: 0...1.5)
                Text(String(format: "%.2f rad/s", teleop.maxAngular))
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    /// 目前送出的速度數值(對照 ros2 topic echo 用)
    private var velocityReadout: some View {
        let t = teleop.currentTwist
        return Text(String(format: "x %+.2f  y %+.2f  ω %+.2f",
                           t.linear.x, t.linear.y, t.angular.z))
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
    }

    // MARK: - 急停

    private var eStopButton: some View {
        Button(action: { teleop.toggleEStop() }) {
            Text(teleop.eStopActive ? "解除急停" : "急停 (空白鍵)")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(teleop.eStopActive ? Color.orange : Color.red)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var keyHint: some View {
        Text("W/S 前後・A/D 平移・Q/E 旋轉")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

/// 按住才動作的按鈕:按下呼叫 onPress,放開呼叫 onRelease
struct HoldButton: View {
    let label: String
    var width: CGFloat = 44
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.title3)
            .frame(width: width, height: 44)
            .background(pressed ? Color.accentColor : Color.gray.opacity(0.25))
            .foregroundColor(pressed ? .white : .primary)
            .cornerRadius(8)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}
