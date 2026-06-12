import SwiftUI

/// SLAM 地圖視圖:即時顯示 /map、機器人位置;點地圖發送導航目標
struct MapView: View {
    @ObservedObject var map: MapModel
    /// 點擊地圖時呼叫(map 座標,公尺)→ AppModel 發布 /goal_pose
    let onGoal: (Double, Double) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("地圖")
                    .font(.headline)
                Spacer()
                if let pose = map.robotPose {
                    Text(String(format: "機器人 (%.2f, %.2f)", pose.x, pose.y))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Text("點地圖 = 導航目標")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                canvas(size: geo.size)
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { value in
                            if let target = map.mapPoint(fromView: value.location,
                                                         viewSize: geo.size) {
                                map.setGoal(x: target.x, y: target.y)
                                onGoal(target.x, target.y)
                            }
                        }
                    )
            }
        }
        .padding(10)
    }

    private func canvas(size: CGSize) -> some View {
        Canvas { context, _ in
            guard map.hasMap, let cgImage = map.image else {
                context.draw(Text("等待 /map…(先啟動建圖或導航)")
                                .font(.caption).foregroundColor(.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            // 地圖影像(等比置中)
            let rect = map.fittedRect(in: size)
            context.draw(Image(decorative: cgImage, scale: 1), in: rect)

            // 導航目標標記(紅圈 + 十字)
            if let goal = map.goal {
                let p = map.viewPoint(fromMap: goal.x, goal.y, viewSize: size)
                let circle = Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8,
                                                    width: 16, height: 16))
                context.stroke(circle, with: .color(.red), lineWidth: 2)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 4, y: p.y))
                cross.addLine(to: CGPoint(x: p.x + 4, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 4))
                cross.addLine(to: CGPoint(x: p.x, y: p.y + 4))
                context.stroke(cross, with: .color(.red), lineWidth: 2)
            }

            // 機器人標記(藍色箭頭,指向行進方向)
            if let pose = map.robotPose {
                let c = map.viewPoint(fromMap: pose.x, pose.y, viewSize: size)
                // map 的 y 向上、畫面 y 向下 → 畫面角度取負
                let a = -pose.yaw
                var tri = Path()
                tri.move(to: CGPoint(x: c.x + 10 * cos(a), y: c.y + 10 * sin(a)))
                tri.addLine(to: CGPoint(x: c.x + 6 * cos(a + 2.5), y: c.y + 6 * sin(a + 2.5)))
                tri.addLine(to: CGPoint(x: c.x + 6 * cos(a - 2.5), y: c.y + 6 * sin(a - 2.5)))
                tri.closeSubpath()
                context.fill(tri, with: .color(.blue))
            }
        }
        .background(Color.black.opacity(0.85))
        .cornerRadius(8)
    }
}
