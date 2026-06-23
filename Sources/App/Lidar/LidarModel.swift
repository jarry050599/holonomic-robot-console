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
    /// 資料逾時:連線著但超過 2 秒沒新掃描(網路停滯偵測)
    @Published private(set) var isStale = false
    private var staleTimer: Timer?

    // MARK: - 目標追蹤與測距
    /// 追蹤模式開關(開啟後點畫面指定目標)
    @Published var trackingEnabled = false { didSet { if !trackingEnabled { clearTarget() } } }
    /// 目前追蹤到的目標(機器人座標,公尺);nil = 未鎖定
    @Published private(set) var trackedPoint: CGPoint?
    /// 目標距離(公尺)
    @Published private(set) var trackedDistance: Double?
    /// 目標方位(弧度,機器人座標:0=正前、+ 左、- 右)
    @Published private(set) var trackedBearing: Double?
    /// 目標暫時丟失(連續數幀找不到,保留最後位置)
    @Published private(set) var targetLost = false
    private var lostFrames = 0

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
        updateTracking()
    }

    // MARK: - 目標追蹤與測距

    /// 使用者點畫面指定目標(機器人座標,公尺):鎖定最接近點擊處的雷射點
    func setTarget(robotX x: Double, robotY y: Double) {
        if let p = nearestPoint(to: CGPoint(x: x, y: y), within: 1.0) {
            lockOnto(p)
        } else if let bp = nearestPointAlong(bearing: atan2(y, x), window: 0.25) {
            // 點擊處附近沒點,改沿點擊方向找最近障礙
            lockOnto(bp)
        } else {
            clearTarget()
        }
    }

    func clearTarget() {
        trackedPoint = nil; trackedDistance = nil; trackedBearing = nil
        targetLost = false; lostFrames = 0
    }

    private func lockOnto(_ p: CGPoint) {
        trackedPoint = p
        trackedDistance = hypot(p.x, p.y)
        trackedBearing = atan2(p.y, p.x)
        targetLost = false
        lostFrames = 0
    }

    /// 每幀以 gating 跟蹤:找上一個目標位置附近最近的點,跟著它移動
    private func updateTracking() {
        guard trackingEnabled, let prev = trackedPoint else { return }
        if let p = nearestPoint(to: prev, within: 0.6) {
            lockOnto(p)
        } else {
            lostFrames += 1
            if lostFrames > 5 { targetLost = true }   // 連續找不到:保留最後位置並標記丟失
        }
    }

    /// 找離 q 最近、且在 radius 內的點
    private func nearestPoint(to q: CGPoint, within radius: Double) -> CGPoint? {
        var best: CGPoint?
        var bestD = radius
        for p in points {
            let d = hypot(p.x - q.x, p.y - q.y)
            if d < bestD { bestD = d; best = p }
        }
        return best
    }

    /// 沿指定方位(±window 弧度)找最近障礙點
    private func nearestPointAlong(bearing: Double, window: Double) -> CGPoint? {
        var best: CGPoint?
        var bestR = Double.infinity
        for p in points {
            var db = abs(atan2(p.y, p.x) - bearing)
            if db > .pi { db = 2 * .pi - db }
            if db <= window {
                let r = hypot(p.x, p.y)
                if r < bestR { bestR = r; best = p }
            }
        }
        return best
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
        isStale = false
        // 2 秒沒有下一筆 → 標記資料逾時(WebSocket 停滯但 TCP 未斷的情況)
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isStale = true
                self?.scanHz = 0
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
