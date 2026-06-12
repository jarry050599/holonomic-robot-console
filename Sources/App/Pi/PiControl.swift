import Foundation

/// 樹莓派遠端控制:透過 ssh 呼叫 Pi 上的 robot.sh,免開終端機
/// 需求:已 ssh-copy-id 過(BatchMode 金鑰登入,不會跳密碼)
@MainActor
final class PiControl: ObservableObject {

    @Published private(set) var busy = false
    /// 最後一次指令的輸出(顯示在操作列)
    @Published private(set) var lastMessage = ""

    private let remoteScript = "~/ros2_ws/src/robot_bringup/scripts/robot.sh"

    /// 執行 robot.sh 子指令(bringup/slam/save/slam-stop/nav2/nav2-stop/status)
    @discardableResult
    func run(_ subcommand: String, host: String, user: String = "pi") async -> Bool {
        guard !busy else { return false }
        busy = true
        lastMessage = "\(subcommand)…"
        defer { busy = false }

        let result = await Self.ssh(
            to: "\(user)@\(host.trimmingCharacters(in: .whitespaces))",
            command: "bash \(remoteScript) \(subcommand)")
        lastMessage = result.output.isEmpty
            ? (result.ok ? "\(subcommand) 完成" : "\(subcommand) 失敗(ssh 連不上?)")
            : result.output
        return result.ok
    }

    /// 背景執行 ssh,回傳 (成功與否, 合併輸出)
    private static func ssh(to target: String, command: String)
        async -> (ok: Bool, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                // BatchMode:沒金鑰直接失敗,不會卡在密碼提示
                process.arguments = ["-o", "BatchMode=yes",
                                     "-o", "ConnectTimeout=6",
                                     target, command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // 多行輸出取最後兩行(狀態類訊息較有意義)
                    let tail = text.split(separator: "\n").suffix(2).joined(separator: " / ")
                    continuation.resume(returning: (process.terminationStatus == 0, tail))
                } catch {
                    continuation.resume(returning: (false, "ssh 執行失敗:\(error.localizedDescription)"))
                }
            }
        }
    }
}
