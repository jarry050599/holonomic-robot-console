import Foundation

// MARK: - ROS 訊息型別(對應 rosbridge JSON 格式)

/// geometry_msgs/msg/Vector3
struct RosVector3: Codable {
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
}

/// geometry_msgs/msg/Twist:底盤速度指令
struct Twist: Codable {
    var linear = RosVector3()
    var angular = RosVector3()

    /// 全零速度(停車/急停用)
    static let zero = Twist()
}

/// sensor_msgs/msg/LaserScan(只取需要的欄位)
/// 注意:rosbridge 會把 inf/nan 轉成 null,所以 ranges 用 Optional
struct LaserScan: Decodable {
    var angleMin: Double
    var angleMax: Double
    var angleIncrement: Double
    var scanTime: Double
    var rangeMin: Double
    var rangeMax: Double
    var ranges: [Double?]

    enum CodingKeys: String, CodingKey {
        case angleMin = "angle_min"
        case angleMax = "angle_max"
        case angleIncrement = "angle_increment"
        case scanTime = "scan_time"
        case rangeMin = "range_min"
        case rangeMax = "range_max"
        case ranges
    }
}

/// std_msgs/msg/Float32(電池電壓等單值訊息)
struct Float32Msg: Decodable {
    var data: Double
}

// MARK: - rosbridge 協定封包(op 訊息)

/// 送出:宣告要發布的 topic
struct AdvertiseOp: Encodable {
    let op = "advertise"
    let topic: String
    let type: String
}

/// 送出:發布訊息
struct PublishOp<M: Encodable>: Encodable {
    let op = "publish"
    let topic: String
    let msg: M
}

/// 送出:訂閱 topic(throttle_rate 單位毫秒,queue_length=1 只留最新)
struct SubscribeOp: Encodable {
    let op = "subscribe"
    let topic: String
    let type: String
    let throttleRate: Int
    let queueLength: Int

    enum CodingKeys: String, CodingKey {
        case op, topic, type
        case throttleRate = "throttle_rate"
        case queueLength = "queue_length"
    }
}

/// 收到:先解出 op 與 topic,再依 topic 分派給對應的解碼器
struct IncomingHeader: Decodable {
    let op: String
    let topic: String?
}

/// 收到:完整的 publish 封包(msg 依 topic 型別解碼)
struct IncomingPublish<M: Decodable>: Decodable {
    let topic: String
    let msg: M
}
