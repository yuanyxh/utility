import Cocoa

/// 窗口定位工具 — 纯函数，无视图依赖
enum WindowPositioning {
    /// 鼠标附近四象限智能定位（Clipboard 用）
    /// 尝试顺序：右下 → 左下 → 右上 → 左上
    static func nearMouseQuadrant(
        windowSize: NSSize,
        padding: CGFloat = 12,
        screen: NSScreen?,
        mouseLocation: NSPoint? = nil
    ) -> NSPoint {
        let mouse = mouseLocation ?? NSEvent.mouseLocation
        guard let screenFrame = screen?.visibleFrame else {
            return NSPoint(x: mouse.x + padding, y: mouse.y - windowSize.height - padding)
        }

        let candidates: [(x: CGFloat, y: CGFloat)] = [
            (mouse.x + padding, mouse.y - windowSize.height - padding),
            (mouse.x - windowSize.width - padding, mouse.y - windowSize.height - padding),
            (mouse.x + padding, mouse.y + padding),
            (mouse.x - windowSize.width - padding, mouse.y + padding),
        ]

        for candidate in candidates {
            let rect = NSRect(origin: NSPoint(x: candidate.x, y: candidate.y), size: windowSize)
            if screenFrame.contains(rect) {
                return NSPoint(x: candidate.x, y: candidate.y)
            }
        }

        return NSPoint(x: mouse.x + padding, y: mouse.y - windowSize.height - padding)
    }

    /// 屏幕居中偏上（Chat 用）
    static func screenCenter(
        windowSize: NSSize,
        offsetFraction: CGFloat = 0.2,
        screen: NSScreen?
    ) -> NSPoint {
        guard let frame = screen?.visibleFrame else { return .zero }
        let x = frame.midX - windowSize.width / 2
        let y = frame.midY + frame.height * offsetFraction - windowSize.height / 2
        return NSPoint(x: x, y: y)
    }

    /// 记忆位置 → 鼠标位置回退（Translation 用）
    static func savedOrNearMouse(
        windowSize: NSSize,
        key: String,
        screen: NSScreen?
    ) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: key) {
            let savedPoint = NSPointFromString(saved)
            if !NSEqualPoints(savedPoint, .zero) {
                return savedPoint
            }
        }
        return nearMouseQuadrant(windowSize: windowSize, padding: 12, screen: screen)
    }

    /// 保存记忆位置
    static func savePosition(_ origin: NSPoint, forKey key: String) {
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: key)
    }
}
