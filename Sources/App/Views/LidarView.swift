import SwiftUI

/// 雷射點雲視圖:2D 俯視圖,機器人置中,附距離圈與統計資訊
struct LidarView: View {
    @ObservedObject var lidar: LidarModel

    /// 顯示半徑(公尺):點雲與距離圈依此縮放
    @State private var displayRange = 4.5

    var body: some View {
        VStack(spacing: 8) {
            statsBar
            canvas
            recordingBar
        }
        .padding(10)
    }

    // MARK: - 統計列

    private var statsBar: some View {
        HStack {
            Text("雷射掃描")
                .font(.headline)
            Spacer()
            Text(String(format: "%.1f Hz", lidar.scanHz))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            if let nearest = lidar.nearestDistance {
                Text(String(format: "最近 %.2f m", nearest))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(lidar.isWarning ? .red : .secondary)
                    .fontWeight(lidar.isWarning ? .bold : .regular)
            }
        }
    }

    // MARK: - 點雲畫布

    private var canvas: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // 1 公尺對應的像素數:讓 displayRange 剛好貼齊畫布短邊
            let scale = min(size.width, size.height) / 2 / displayRange

            // 尚無資料:只顯示等待文字,不畫其他元素
            guard lidar.hasData else {
                context.draw(
                    Text("等待 /scan…").font(.caption).foregroundColor(.secondary),
                    at: center)
                return
            }

            drawRobot(context: context, center: center)

            // 座標轉換:機器人座標 x 前方 → 螢幕上方;y 左方 → 螢幕左方
            func toScreen(_ p: CGPoint) -> CGPoint {
                CGPoint(x: center.x - p.y * scale, y: center.y - p.x * scale)
            }

            // 點雲(有開直線擬合時點畫淡一點,讓線段當主角)
            var dots = Path()
            for p in lidar.points {
                let s = toScreen(p)
                dots.addRect(CGRect(x: s.x - 1.5, y: s.y - 1.5, width: 3, height: 3))
            }
            let dotColor: Color = lidar.isWarning ? .red : .green
            context.fill(dots, with: .color(lidar.fitLines
                                            ? dotColor.opacity(0.35) : dotColor))

            // 擬合出的直線段
            if lidar.fitLines {
                var strokes = Path()
                for line in lidar.lines {
                    strokes.move(to: toScreen(line[0]))
                    for p in line.dropFirst() { strokes.addLine(to: toScreen(p)) }
                }
                context.stroke(strokes,
                               with: .color(lidar.isWarning ? .red : .cyan),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                  lineJoin: .round))
            }
        }
        .background(Color.black.opacity(0.85))
        .cornerRadius(8)
        .overlay(
            // 障礙物過近:紅框警示(< 0.3 m)
            RoundedRectangle(cornerRadius: 8)
                .stroke(lidar.isWarning ? Color.red : Color.clear, lineWidth: 4)
        )
        .frame(minWidth: 360, minHeight: 360)
    }

    /// 機器人標記:置中的三角形,尖端朝前(上)
    private func drawRobot(context: GraphicsContext, center: CGPoint) {
        var tri = Path()
        tri.move(to: CGPoint(x: center.x, y: center.y - 8))
        tri.addLine(to: CGPoint(x: center.x - 6, y: center.y + 6))
        tri.addLine(to: CGPoint(x: center.x + 6, y: center.y + 6))
        tri.closeSubpath()
        context.fill(tri, with: .color(.cyan))
    }

    // MARK: - 錄製/回放列(M3)

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Button(lidar.isRecording ? "停止錄製" : "錄製") {
                lidar.isRecording ? lidar.stopRecording() : lidar.startRecording()
            }
            Button(lidar.isPlayingBack ? "停止回放" : "回放") {
                lidar.isPlayingBack ? lidar.stopPlayback() : lidar.startPlayback()
            }
            .disabled(lidar.recording.isEmpty && !lidar.isPlayingBack)

            if lidar.isRecording {
                Text("● 錄製中")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if lidar.isPlayingBack {
                Text("▶ 回放中")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            Spacer()
            Toggle("濾噪", isOn: $lidar.filterNoise)
                .toggleStyle(.checkbox)
            Toggle("直線", isOn: $lidar.fitLines)
                .toggleStyle(.checkbox)
            // 顯示範圍縮放
            Text("範圍")
                .font(.caption)
            Slider(value: $displayRange, in: 1...10)
                .frame(width: 100)
            Text(String(format: "%.1f m", displayRange))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
    }
}
