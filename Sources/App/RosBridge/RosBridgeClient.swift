import Foundation

/// rosbridge WebSocket 客戶端
/// 使用原生 URLSessionWebSocketTask,以 JSON 協定與 rosbridge_websocket(預設 9090)溝通。
/// advertise / subscribe 的意圖會先登記起來,連線成功(或重連)時自動重送。
@MainActor
final class RosBridgeClient: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected   // 未連線
        case connecting     // 連線中
        case connected      // 已連線
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastError: String?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    /// 保活 ping:偵測「TCP 沒斷但實際停滯」的連線(Wi-Fi 不穩時常見)
    private var pingTimer: Timer?
    /// 自動重連(非使用者主動斷線時,WiFi 恢復後自動接回)
    private var reconnectTimer: Timer?
    private var lastHost: String?
    private var lastPort: Int?
    private var userInitiatedDisconnect = false
    /// 資料停滯自癒:連線著但久未收到任何訊息 → 重建連線(重新訂閱)
    private var lastInboundTime = Date()
    private var dataWatchdogTimer: Timer?
    /// 連線著但超過此秒數沒收到任何訊息,視為停滯並重連
    private let staleReconnectSeconds: TimeInterval = 8

    /// 已登記的 advertise 意圖(連線後重送)
    private var advertisedTopics: [(topic: String, type: String)] = []
    /// 已登記的訂閱:topic → (型別, 節流毫秒, 原始資料處理器)
    private var subscriptions: [String: (type: String, throttleMs: Int, handler: (Data) -> Void)] = [:]

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override init() {
        super.init()
        // delegate 用來接收 WebSocket 開啟/關閉事件
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - 連線管理

    func connect(host: String, port: Int) {
        guard state == .disconnected else { return }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "ws://\(trimmed):\(port)") else {
            lastError = "無效的位址:\(trimmed):\(port)"
            return
        }
        // 記住連線目標供自動重連用;清除「使用者主動斷線」旗標
        lastHost = trimmed
        lastPort = port
        userInitiatedDisconnect = false
        lastError = nil
        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(on: task)
    }

    func disconnect() {
        userInitiatedDisconnect = true   // 使用者主動斷線:不要自動重連
        stopReconnect()
        stopPing()
        stopDataWatchdog()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .disconnected
    }

    /// 連線中斷(錯誤或對方關閉)時的統一處理
    private func handleDisconnect(message: String?) {
        guard state != .disconnected else { return }
        stopPing()
        stopDataWatchdog()
        task = nil
        state = .disconnected
        if let message { lastError = message }
        // 非使用者主動斷線 → 啟動自動重連(WiFi 恢復後自動接回)
        if !userInitiatedDisconnect { startReconnect() }
    }

    /// 每 3 秒嘗試重連,直到接上或使用者主動斷線
    private func startReconnect() {
        guard reconnectTimer == nil, let host = lastHost, let port = lastPort else { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.userInitiatedDisconnect { self.stopReconnect(); return }
                if self.state == .disconnected {
                    self.lastError = "連線中斷,自動重連中…"
                    self.connect(host: host, port: port)
                }
            }
        }
    }

    private func stopReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    /// 每 5 秒 ping 一次;失敗即視為斷線(否則停滯的連線會永遠假裝活著)
    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let task = self.task else { return }
                task.sendPing { error in
                    guard error != nil else { return }
                    Task { @MainActor in
                        self.handleDisconnect(message: "連線停滯(ping 失敗),已斷線")
                    }
                }
            }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// 資料停滯自癒:連線著但久未收到訊息(訂閱失效/半死連線)→ 主動重建連線
    private func startDataWatchdog() {
        stopDataWatchdog()
        lastInboundTime = Date()
        dataWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .connected, !self.subscriptions.isEmpty else { return }
                if Date().timeIntervalSince(self.lastInboundTime) > self.staleReconnectSeconds {
                    // 久未收到任何資料 → 重建連線(handleDisconnect 會觸發自動重連)
                    let t = self.task
                    self.handleDisconnect(message: "資料停滯,重新連線中…")
                    t?.cancel(with: .abnormalClosure, reason: nil)
                }
            }
        }
    }

    private func stopDataWatchdog() {
        dataWatchdogTimer?.invalidate()
        dataWatchdogTimer = nil
    }

    // MARK: - rosbridge 操作

    /// 登記並(若已連線)送出 advertise
    func advertise(topic: String, type: String) {
        advertisedTopics.append((topic, type))
        if state == .connected {
            send(AdvertiseOp(topic: topic, type: type))
        }
    }

    /// 發布訊息;未連線時靜默忽略
    func publish<M: Encodable>(topic: String, msg: M) {
        guard state == .connected else { return }
        send(PublishOp(topic: topic, msg: msg))
    }

    /// 登記訂閱;handler 在主執行緒收到解碼後的訊息
    func subscribe<M: Decodable>(topic: String, type: String, throttleMs: Int,
                                 handler: @escaping (M) -> Void) {
        let decoder = self.decoder
        subscriptions[topic] = (type, throttleMs, { data in
            // 依 topic 對應的具體型別解碼;格式不符就丟棄該筆
            if let packet = try? decoder.decode(IncomingPublish<M>.self, from: data) {
                handler(packet.msg)
            }
        })
        if state == .connected {
            sendSubscribe(topic: topic)
        }
    }

    private func sendSubscribe(topic: String) {
        guard let sub = subscriptions[topic] else { return }
        send(SubscribeOp(topic: topic, type: sub.type,
                         throttleRate: sub.throttleMs, queueLength: 1))
    }

    private func send<T: Encodable>(_ packet: T) {
        guard let task, let data = try? encoder.encode(packet),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.handleDisconnect(message: "傳送失敗:\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 接收迴圈

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure(let error):
                    self.handleDisconnect(message: error.localizedDescription)
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8) {
                        self.dispatch(data)
                    }
                    self.receiveLoop(on: task)  // 繼續收下一筆
                }
            }
        }
    }

    /// 解析收到的封包並分派給對應 topic 的訂閱者
    private func dispatch(_ data: Data) {
        lastInboundTime = Date()   // 收到任何資料就更新(供停滯自癒判斷)
        guard let header = try? decoder.decode(IncomingHeader.self, from: data) else { return }
        if header.op == "publish", let topic = header.topic,
           let sub = subscriptions[topic] {
            sub.handler(data)
        }
    }
}

// MARK: - WebSocket 開啟/關閉事件

extension RosBridgeClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            self.state = .connected
            self.stopReconnect()        // 接上了,停止重連嘗試
            self.startPing()
            self.startDataWatchdog()    // 開始監看資料是否持續流入
            // 連線成功:重送所有登記過的 advertise 與 subscribe
            for item in self.advertisedTopics {
                self.send(AdvertiseOp(topic: item.topic, type: item.type))
            }
            for topic in self.subscriptions.keys {
                self.sendSubscribe(topic: topic)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            self.handleDisconnect(message: "連線已關閉")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Task { @MainActor in
            guard self.task === task else { return }
            self.handleDisconnect(message: error?.localizedDescription ?? "連線中斷")
        }
    }
}
