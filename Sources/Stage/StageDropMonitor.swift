import Cocoa

/// 全局拖拽监听器
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var timer: Timer?
    private var wasDragging = false
    private var windowVisible = false

    private let zoneSize: CGFloat = 80
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
        let isPressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let mouse = NSEvent.mouseLocation
        let zone = NSRect(x: 0, y: 0, width: zoneSize, height: zoneSize)
        let inZone = zone.contains(mouse)
        let items = (try? StageManager.shared.count()) ?? 0

        if isPressed && inZone {
            if !windowVisible {
                stageWindow?.show()
                windowVisible = true
            }
            wasDragging = true
        } else if !isPressed && wasDragging {
            wasDragging = false
            let windowFrame = stageWindow?.window?.frame ?? .zero
            let inWindow = windowFrame.contains(mouse)

            if !inWindow && items == 0 {
                stageWindow?.close()
                windowVisible = false
            } else if !inWindow {
                DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
                    guard let self = self, !self.wasDragging else { return }
                    if !(self.stageWindow?.window?.frame.contains(NSEvent.mouseLocation) ?? false) {
                        self.stageWindow?.close()
                        self.windowVisible = false
                    }
                }
            }
        } else if !isPressed && items > 0 && !windowVisible {
            stageWindow?.show()
            windowVisible = true
        }
    }

    public func didCloseWindow() {
        windowVisible = false
    }
}
