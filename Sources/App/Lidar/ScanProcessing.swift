import Foundation
import CoreGraphics

/// 雷射掃描後處理:雜訊過濾與直線擬合(純函式,不依賴 UI)
enum ScanProcessing {

    struct Result {
        var points: [CGPoint]      // 過濾後點雲(機器人座標,公尺)
        var lines: [[CGPoint]]     // 擬合出的折線(每條 ≥ 2 點)
        var nearest: Double?       // 最近障礙物距離(用過濾後的點,避免雜訊誤觸警示)
    }

    /// 主管線:LaserScan → 過濾 → 轉直角座標 → 分群 → 直線擬合
    static func process(scan: LaserScan, filterNoise: Bool, fitLines: Bool) -> Result {
        var ranges = scan.ranges.map { r -> Double? in
            guard let r, r >= scan.rangeMin, r <= scan.rangeMax else { return nil }
            return r
        }
        if filterNoise {
            ranges = medianFilter(ranges, window: 5)
            ranges = removeIsolated(ranges, jump: 0.3)
        }

        // 轉直角座標(保留掃描順序供分群)
        var pts: [(point: CGPoint, range: Double, index: Int)] = []
        var nearest = Double.infinity
        for (i, r) in ranges.enumerated() {
            guard let r else { continue }
            let angle = scan.angleMin + Double(i) * scan.angleIncrement
            pts.append((CGPoint(x: r * cos(angle), y: r * sin(angle)), r, i))
            if r < nearest { nearest = r }
        }

        var lines: [[CGPoint]] = []
        if fitLines {
            for cluster in clusters(of: pts, angleIncrement: scan.angleIncrement)
            where cluster.count >= 5 {
                let line = douglasPeucker(cluster, epsilon: 0.05)
                if line.count >= 2 { lines.append(line) }
            }
        }
        return Result(points: pts.map(\.point), lines: lines,
                      nearest: nearest.isFinite ? nearest : nil)
    }

    /// 中值濾波:壓掉單點突波,保留邊緣(視窗內有效值不足就原樣保留)
    static func medianFilter(_ ranges: [Double?], window: Int) -> [Double?] {
        let half = window / 2
        return ranges.indices.map { i in
            guard ranges[i] != nil else { return nil }
            let neighbors = (max(0, i - half)...min(ranges.count - 1, i + half))
                .compactMap { ranges[$0] }
            guard neighbors.count >= 3 else { return ranges[i] }
            return neighbors.sorted()[neighbors.count / 2]
        }
    }

    /// 孤立點剔除:與前後最近有效鄰點的距離差都超過門檻 → 視為雜訊丟棄
    static func removeIsolated(_ ranges: [Double?], jump: Double) -> [Double?] {
        func neighbor(_ i: Int, step: Int) -> Double? {
            var j = i + step
            // 最多找兩格,角度差太大就不算鄰點
            for _ in 0..<2 {
                guard ranges.indices.contains(j) else { return nil }
                if let r = ranges[j] { return r }
                j += step
            }
            return nil
        }
        return ranges.indices.map { i in
            guard let r = ranges[i] else { return nil }
            let prevOK = neighbor(i, step: -1).map { abs($0 - r) <= jump } ?? false
            let nextOK = neighbor(i, step: +1).map { abs($0 - r) <= jump } ?? false
            return (prevOK || nextOK) ? r : nil
        }
    }

    /// 依掃描順序分群:索引斷開或相鄰點歐氏距離跳變就切新群
    static func clusters(of pts: [(point: CGPoint, range: Double, index: Int)],
                         angleIncrement: Double) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var prev: (point: CGPoint, range: Double, index: Int)?
        for p in pts {
            if let prev {
                let gap = p.index - prev.index
                let dist = hypot(p.point.x - prev.point.x, p.point.y - prev.point.y)
                // 門檻隨距離與角度間隔放大(遠處相鄰點本來就比較開)
                let threshold = max(0.15, 4 * p.range * angleIncrement * Double(gap))
                if gap > 3 || dist > threshold {
                    result.append(current)
                    current = []
                }
            }
            current.append(p.point)
            prev = p
        }
        result.append(current)
        return result
    }

    /// Douglas-Peucker 折線簡化:把一串點拉成少數頂點的直線段
    static func douglasPeucker(_ pts: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let first = pts.first!, last = pts.last!
        var maxDist = 0.0
        var maxIndex = 0
        for i in 1..<(pts.count - 1) {
            let d = perpendicularDistance(pts[i], lineFrom: first, to: last)
            if d > maxDist { maxDist = d; maxIndex = i }
        }
        if maxDist > epsilon {
            let left = douglasPeucker(Array(pts[...maxIndex]), epsilon: epsilon)
            let right = douglasPeucker(Array(pts[maxIndex...]), epsilon: epsilon)
            return left.dropLast() + right
        }
        return [first, last]
    }

    private static func perpendicularDistance(_ p: CGPoint,
                                              lineFrom a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
    }
}
