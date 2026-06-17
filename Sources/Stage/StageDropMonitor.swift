import Cocoa

/// 全局拖拽监听器 — 事件驱动，无轮询
/// 拖拽开始时弹出窗口（窗口本身即触发面板），拖入松手暂存
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var eventTap: CFMachPort?
    private var isDragging = false
    private var windowVisible = false

    private init() {}

    public func start(with window: StageWindowController) {
        stageWindow = window
        installEventTap()
    }

    public func stop() {
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func installEventTap() {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let ctrl = Unmanaged<StageDropMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return ctrl.handleEvent(type: type, event: event)
        }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: ptr
        ) {
            eventTap = tap
            let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .leftMouseDown:
            isDragging = true
        case .leftMouseUp:
            isDragging = false
            let mouse = NSEvent.mouseLocation
            let items = (try? StageManager.shared.count()) ?? 0
            // 鼠标不在窗口内 + 无内容 → 隐藏
            if let frame = stageWindow?.window?.frame {
                let inWindow = NSRect(x: frame.minX - 20, y: frame.minY - 20,
                                      width: frame.width + 40, height: frame.height + 40)
                    .contains(mouse)
                if !inWindow && items == 0 {
                    stageWindow?.close()
                    windowVisible = false
                }
            }
        case .leftMouseDragged:
            guard isDragging else { break }
            let mouse = NSEvent.mouseLocation
            let windowFrame = stageWindow?.window?.frame ?? .zero
            let hitZone = NSRect(x: windowFrame.minX - 20, y: windowFrame.minY - 20,
                                 width: windowFrame.width + 40, height: windowFrame.height + 40)

            if !windowVisible && isDragging {
                // 开始拖拽 → 显示窗口
                stageWindow?.show()
                windowVisible = true
            }

            // 鼠标在窗口附近 → 保持显示；远离 → 关闭（无内容时）
            if windowVisible && !hitZone.contains(mouse) {
                let items = (try? StageManager.shared.count()) ?? 0
                if items == 0 {
                    stageWindow?.close()
                    windowVisible = false
                }
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    public func didCloseWindow() {
        windowVisible = false
    }
}
