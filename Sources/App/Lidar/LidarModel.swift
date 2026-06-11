import Foundation
import CoreGraphics

/// 雷射掃描資料模型:把 LaserScan 轉成直角座標點雲,並統計頻率與最近障礙物
@MainActor
final class LidarModel: ObservableObject {

    /// 點雲(機器人座標系,單位公尺:x 前方、y 左方)
    @Published private(set) var points: [CGPoint] = []
    /// 直線擬合結果(每條折線 ≥ 2 個頂點)
    @Published private(set) var lines: [[CGPoint]] = []
    /// 雜訊過濾開關(中值濾波 + 孤立點剔除)
    @Published var filterNoise = true { didSet { reprocessLast() } }
    /// 直線擬合開關(分群 + Douglas-Peucker)
    @Published var fitLines = true { didSet { reprocessLast() } }
    /// 最後一筆原始掃描(切換開關時重新處理用)
    private var lastScan: LaserScan?
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

    /// 把 LaserScan 經過濾與擬合後更新顯示資料
    private func apply(_ scan: LaserScan) {
        hasData = true
        lastScan = scan
        let result = ScanProcessing.process(scan: scan,
                                            filterNoise: filterNoise,
                                            fitLines: fitLines)
        points = result.points
        lines = result.lines
        nearestDistance = result.nearest
    }

    /// 切換過濾/擬合開關時,用最後一筆掃描立即重算
    private func reprocessLast() {
        if let lastScan { apply(lastScan) }
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
