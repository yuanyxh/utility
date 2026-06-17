import Cocoa

/// 全局拖拽监听器 — 检测鼠标拖拽 + 左下角激活区域
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var timer: Timer?
    private var wasDragging = false
    private var windowVisible = false

    /// 激活区域大小
    private let zoneSize: CGFloat = 80
    /// 离开区域的后置延时（秒）
    private let dismissDelay: TimeInterval = 0.3

    private init() {}

    public func start(with window: StageWindowController) {
        stageWindow = window
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let window = stageWindow else { return }

        let isPressed = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, .left)
        let mouse = NSEvent.mouseLocation
        let zone = NSRect(x: 0, y: 0, width: zoneSize, height: zoneSize)
        let inZone = zone.contains(mouse)
        let items = (try? StageManager.shared.count()) ?? 0

        if isPressed && inZone {
            // 正在拖拽 + 鼠标在激活区 → 显示窗口
            if !windowVisible {
                window.show()
                windowVisible = true
            }
            wasDragging = true
        } else if !isPressed && wasDragging {
            // 拖拽结束
            wasDragging = false

            // 如果鼠标在窗口区域内，保持显示
            let windowFrame = window.window?.frame ?? .zero
            let inWindow = windowFrame.contains(mouse)

            if !inWindow && items == 0 {
                window.close()
                windowVisible = false
            } else if !inWindow {
                // 有内容但不在窗口内 → 延迟关闭
                DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
                    guard let self = self, !self.wasDragging else { return }
                    if !(self.stageWindow?.window?.frame.contains(NSEvent.mouseLocation) ?? false) {
                        window.close()
                        self.windowVisible = false
                    }
                }
            }
        } else if !isPressed && items > 0 && !windowVisible {
            // 有内容常驻显示（除非手动关闭）
            window.show()
            windowVisible = true
        }
    }

    /// 手动关闭窗口时调用
    public func didCloseWindow() {
        windowVisible = false
    }
}
