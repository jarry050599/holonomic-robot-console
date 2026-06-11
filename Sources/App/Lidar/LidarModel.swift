import Foundation
import CoreGraphics

/// 雷射掃描資料模型:把 LaserScan 轉成直角座標點雲,並統計頻率與最近障礙物
@MainActor
final class LidarModel: ObservableObject {

    /// 點雲(機器人座標系,單位公尺:x 前方、y 左方)
    @Published private(set) var points: [CGPoint] = []
    /// 掃描更新頻率(Hz,移動平均)
    @Published private(set) var scanHz: Double = 0
    /// 最近障礙物距離(公尺);nil = 無有效點
    @Published private(set) var nearestDistance: Double?
    /// 是否曾收到資料(顯示「等待 /scan…」用)
    @Published private(set) var hasData = false

    /// 警示門檻:最近障礙物小於此距離畫面變紅
    static let warningDistance = 0.3

    /// 是否進入警示狀態
    var isWarning: Bool {
        if let d = nearestDistance { return d < Self.warningDistance }
        return false
    }

    /// 最近幾筆訊息的到達時間(算頻率用)
    private var arrivalTimes: [Date] = []

    // MARK: - 錄製與回放(M3)

    /// 錄下的掃描(時間戳 + 原始訊息)
    private(set) var recording: [(time: Date, scan: LaserScan)] = []
    @Published var isRecording = false
    @Published private(set) var isPlayingBack = false
    private var playbackTask: Task<Void, Never>?

    // MARK: - 更新

    /// 收到一筆 /scan
    func update(with scan: LaserScan) {
        guard !isPlayingBack else { return }   // 回放中忽略即時資料
        if isRecording {
            recording.append((Date(), scan))
        }
        trackArrival()
        apply(scan)
    }

    /// 把 LaserScan 轉成點雲並更新統計
    private func apply(_ scan: LaserScan) {
        hasData = true
        var pts: [CGPoint] = []
        pts.reserveCapacity(scan.ranges.count)
        var nearest = Double.infinity
        for (i, range) in scan.ranges.enumerated() {
            // rosbridge 把 inf/nan 轉成 null;再過濾量程外的值
            guard let r = range, r >= scan.rangeMin, r <= scan.rangeMax else { continue }
            let angle = scan.angleMin + Double(i) * scan.angleIncrement
            pts.append(CGPoint(x: r * cos(angle), y: r * sin(angle)))
            if r < nearest { nearest = r }
        }
        points = pts
        nearestDistance = nearest.isFinite ? nearest : nil
    }

    /// 用最近 10 筆到達間隔估掃描頻率
    private func trackArrival() {
        let now = Date()
        arrivalTimes.append(now)
        if arrivalTimes.count > 10 { arrivalTimes.removeFirst() }
        if arrivalTimes.count >= 2 {
            let span = now.timeIntervalSince(arrivalTimes[0])
            if span > 0 {
                scanHz = Double(arrivalTimes.count - 1) / span
            }
        }
    }

    // MARK: - 錄製/回放控制

    func startRecording() {
        recording.removeAll()
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }

    /// 依原始時間間隔回放錄下的掃描
    func startPlayback() {
        guard !recording.isEmpty, !isPlayingBack else { return }
        isRecording = false
        isPlayingBack = true
        let frames = recording
        playbackTask = Task { [weak self] in
            for (i, frame) in frames.enumerated() {
                if Task.isCancelled { break }
                if i > 0 {
                    let gap = frame.time.timeIntervalSince(frames[i - 1].time)
                    try? await Task.sleep(nanoseconds: UInt64(max(0.01, min(gap, 1.0)) * 1_000_000_000))
                }
                await MainActor.run { self?.apply(frame.scan) }
            }
            await MainActor.run { self?.isPlayingBack = false }
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlayingBack = false
    }
}
