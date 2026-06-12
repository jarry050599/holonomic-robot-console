import Foundation
import CoreGraphics

/// SLAM 地圖模型:OccupancyGrid → 灰階影像、機器人位姿、座標換算
@MainActor
final class MapModel: ObservableObject {

    /// 地圖灰階影像(列 0 = 畫面上方;已做上下翻轉)
    @Published private(set) var image: CGImage?
    /// 機器人在 map 座標的位姿(x, y 公尺,yaw 弧度)
    @Published private(set) var robotPose: (x: Double, y: Double, yaw: Double)?
    /// 最後送出的導航目標(map 座標,畫標記用)
    @Published private(set) var goal: (x: Double, y: Double)?
    @Published private(set) var hasMap = false

    // 地圖幾何(座標換算用)
    private var resolution = 0.05
    private var originX = 0.0
    private var originY = 0.0
    private var gridWidth = 0
    private var gridHeight = 0

    // MARK: - 更新

    /// 收到一筆 /map:轉灰階影像
    func update(with grid: OccupancyGrid) {
        let w = grid.info.width, h = grid.info.height
        guard w > 0, h > 0, grid.data.count >= w * h else { return }
        resolution = grid.info.resolution
        originX = grid.info.origin.position.x
        originY = grid.info.origin.position.y
        gridWidth = w
        gridHeight = h

        // OccupancyGrid 列 0 在下方(y 向上),畫面列 0 在上方 → 上下翻轉
        var pixels = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = (h - 1 - row) * w
            for col in 0..<w {
                let v = grid.data[src + col]
                // -1 未知 → 深灰;0 自由 → 亮;100 障礙 → 黑
                pixels[row * w + col] = v < 0 ? 70 : UInt8(max(0, 235 - Int(v) * 2))
            }
        }
        image = pixels.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return ctx.makeImage()
        }
        hasMap = image != nil
    }

    /// 收到機器人位姿(slam_toolbox /pose 或 amcl /amcl_pose)
    func updateRobot(with msg: PoseWithCovarianceStamped) {
        let p = msg.pose.pose
        // 平面 yaw:由四元數 z, w 取出
        let yaw = atan2(2 * p.orientation.w * p.orientation.z,
                        1 - 2 * p.orientation.z * p.orientation.z)
        robotPose = (p.position.x, p.position.y, yaw)
    }

    func setGoal(x: Double, y: Double) {
        goal = (x, y)
    }

    // MARK: - 座標換算(地圖 ↔ 畫面)

    /// 地圖影像在指定 view 大小下的等比縮放顯示範圍
    func fittedRect(in size: CGSize) -> CGRect {
        guard gridWidth > 0, gridHeight > 0 else { return .zero }
        let scale = min(size.width / CGFloat(gridWidth),
                        size.height / CGFloat(gridHeight))
        let w = CGFloat(gridWidth) * scale, h = CGFloat(gridHeight) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2,
                      width: w, height: h)
    }

    /// 畫面點 → map 座標(公尺);點在地圖外回 nil
    func mapPoint(fromView pt: CGPoint, viewSize: CGSize) -> (x: Double, y: Double)? {
        let rect = fittedRect(in: viewSize)
        guard rect.width > 0, rect.contains(pt) else { return nil }
        let col = Double((pt.x - rect.minX) / rect.width) * Double(gridWidth)
        let rowFromTop = Double((pt.y - rect.minY) / rect.height) * Double(gridHeight)
        let row = Double(gridHeight) - rowFromTop          // 翻回 grid 座標(y 向上)
        return (originX + col * resolution, originY + row * resolution)
    }

    /// map 座標 → 畫面點
    func viewPoint(fromMap x: Double, _ y: Double, viewSize: CGSize) -> CGPoint {
        let rect = fittedRect(in: viewSize)
        let col = (x - originX) / resolution
        let row = (y - originY) / resolution
        return CGPoint(
            x: rect.minX + CGFloat(col / Double(gridWidth)) * rect.width,
            y: rect.minY + CGFloat((Double(gridHeight) - row) / Double(gridHeight)) * rect.height)
    }
}
