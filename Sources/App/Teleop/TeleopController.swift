import SwiftUI
import AppKit

/// 遙控控制器:鍵盤/虛擬按鈕 → 三軸速度,以固定頻率連續發布 /cmd_vel
///
/// 設計:按鍵與按鈕只改「狀態」,另由 15 Hz 計時器讀狀態組 Twist 發送,
/// 滿足「連續發布、放開立即歸零、急停連發零速度」的需求。
@MainActor
final class TeleopController: ObservableObject {

    /// 速度上限(由滑桿調整)
    @Published var maxLinear: Double = 0.3    // m/s,範圍 0~0.5
    @Published var maxAngular: Double = 1.0   // rad/s,範圍 0~1.5

    /// 急停閂鎖:啟動後持續發零速度,再按空白鍵或點按鈕解除
    @Published private(set) var eStopActive = false

    /// 目前按住的鍵盤鍵(顯示用 + 計算速度)
    @Published private(set) var pressedKeys: Set<Character> = []

    /// 虛擬按鈕目前命令的方向(-1/0/+1 三軸)
    @Published private(set) var buttonAxes = (x: 0.0, y: 0.0, z: 0.0)

    /// 目前實際送出的速度(顯示用)
    @Published private(set) var currentTwist = Twist.zero

    private let ros: RosBridgeClient
    private var keyMonitor: Any?
    private var publishTimer: Timer?

    /// 遙控用的按鍵集合(攔截不外漏,避免系統提示音)
    private static let teleopKeys: Set<Character> = ["w", "a", "s", "d", "q", "e", " "]

    init(ros: RosBridgeClient) {
        self.ros = ros
    }

    // MARK: - 啟動/停止

    func start() {
        guard keyMonitor == nil else { return }
        // 監聽本視窗的按下/放開事件(macOS 12 沒有 onKeyPress,用 NSEvent monitor)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event)
        }
        // 15 Hz 連續發布
        publishTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishTick() }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        publishTimer?.invalidate()
        publishTimer = nil
    }

    // MARK: - 鍵盤事件

    private func handle(event: NSEvent) -> NSEvent? {
        // 文字輸入框(host/port 欄位)聚焦時放行,不攔截打字
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return event
        }
        // 有修飾鍵(⌘ 等)時放行,保留系統快捷鍵
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return event
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first,
              Self.teleopKeys.contains(ch) else {
            return event
        }
        switch event.type {
        case .keyDown:
            if event.isARepeat { return nil }  // 忽略自動重複
            if ch == " " {
                toggleEStop()
            } else {
                pressedKeys.insert(ch)
            }
        case .keyUp:
            pressedKeys.remove(ch)
        default:
            break
        }
        return nil  // 吞掉事件,避免按鍵提示音
    }

    // MARK: - 急停與虛擬按鈕

    /// 切換急停閂鎖(空白鍵或畫面按鈕)
    func toggleEStop() {
        eStopActive.toggle()
        if eStopActive {
            pressedKeys.removeAll()
            buttonAxes = (0, 0, 0)
            // 立即先送一筆零速度,不等下一個 tick
            ros.publish(topic: "/cmd_vel", msg: Twist.zero)
            currentTwist = .zero
        }
    }

    /// 虛擬按鈕按下:設定方向(各軸 -1/0/+1);放開時傳 (0,0,0)
    func setButtonAxes(x: Double, y: Double, z: Double) {
        guard !eStopActive else { return }
        buttonAxes = (x, y, z)
    }

    func releaseButtons() {
        buttonAxes = (0, 0, 0)
    }

    // MARK: - 發布

    /// 由鍵盤與按鈕狀態組出目前速度
    private func composeTwist() -> Twist {
        if eStopActive { return .zero }
        // 鍵盤:W/S=前後(x)、A/D=左右平移(y,ROS 慣例左為正)、Q/E=旋轉(z,逆時針為正)
        var x = (pressedKeys.contains("w") ? 1.0 : 0) - (pressedKeys.contains("s") ? 1.0 : 0)
        var y = (pressedKeys.contains("a") ? 1.0 : 0) - (pressedKeys.contains("d") ? 1.0 : 0)
        var z = (pressedKeys.contains("q") ? 1.0 : 0) - (pressedKeys.contains("e") ? 1.0 : 0)
        // 虛擬按鈕與鍵盤疊加後夾在 ±1
        x = max(-1, min(1, x + buttonAxes.x))
        y = max(-1, min(1, y + buttonAxes.y))
        z = max(-1, min(1, z + buttonAxes.z))
        var twist = Twist()
        twist.linear.x = x * maxLinear
        twist.linear.y = y * maxLinear
        twist.angular.z = z * maxAngular
        return twist
    }

    /// 15 Hz 計時器:連線中就持續發布(含零速度,兼作樹莓派端 watchdog 的心跳)
    private func publishTick() {
        guard ros.state == .connected else {
            currentTwist = .zero
            return
        }
        let twist = composeTwist()
        currentTwist = twist
        ros.publish(topic: "/cmd_vel", msg: twist)
    }
}
