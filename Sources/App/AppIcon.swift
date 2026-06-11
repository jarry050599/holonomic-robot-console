import AppKit

/// 程式繪製的 App 圖示(雷射掃描 + 機器人主題)。
/// SPM 執行檔沒有 app bundle,改在啟動時設定 Dock 圖示。
enum AppIcon {

    /// 產生 512×512 圖示
    static func make() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    private static func draw(in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // 背景:深藍漸層圓角方形(macOS 圖示常見外型)
        let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 16, dy: 16),
                                  xRadius: 96, yRadius: 96)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.24, alpha: 1),
                                  ending: NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: 1))
        gradient?.draw(in: bgPath, angle: -90)

        // 雷射距離圈
        NSColor.white.withAlphaComponent(0.18).setStroke()
        for radius in stride(from: 70.0, through: 210.0, by: 70.0) {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 6
            ring.stroke()
        }

        // 掃描扇形(綠色,模擬雷射 sweep)
        let sweep = NSBezierPath()
        sweep.move(to: center)
        sweep.appendArc(withCenter: center, radius: 210,
                        startAngle: 35, endAngle: 75)
        sweep.close()
        NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.4, alpha: 0.25).setFill()
        sweep.fill()

        // 掃描點(沿著一圈牆面的綠點)
        NSColor(calibratedRed: 0.3, green: 0.95, blue: 0.45, alpha: 1).setFill()
        for i in 0..<26 {
            let angle = Double(i) / 26 * 2 * .pi
            // 半徑帶一點波動,像真實點雲
            let radius = 185 + 22 * sin(Double(i) * 1.7)
            let p = NSPoint(x: center.x + radius * cos(angle),
                            y: center.y + radius * sin(angle))
            NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill()
        }

        // 機器人:中央青色三角形(朝上)
        let robot = NSBezierPath()
        robot.move(to: NSPoint(x: center.x, y: center.y + 58))
        robot.line(to: NSPoint(x: center.x - 44, y: center.y - 42))
        robot.line(to: NSPoint(x: center.x + 44, y: center.y - 42))
        robot.close()
        NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 1).setFill()
        robot.fill()
    }
}
