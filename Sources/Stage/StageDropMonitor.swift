import Cocoa

/// 全局拖拽监听器 — 事件驱动，无轮询
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var eventTap: CFMachPort?
    private var isDragging = false
    private var windowVisible = false

    private let zoneSize: CGFloat = 80

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
            // 拖拽结束：若不在窗口内且无内容，关闭
            let mouse = NSEvent.mouseLocation
            let inWindow = stageWindow?.window?.frame.contains(mouse) ?? false
            let items = (try? StageManager.shared.count()) ?? 0
            if !inWindow && items == 0 {
                stageWindow?.close()
                windowVisible = false
            }
        case .leftMouseDragged:
            guard isDragging else { break }
            let mouse = NSEvent.mouseLocation
            let zone = NSRect(x: 0, y: 0, width: zoneSize, height: zoneSize)
            if zone.contains(mouse) {
                if !windowVisible {
                    stageWindow?.show()
                    windowVisible = true
                }
            } else if windowVisible {
                // 鼠标离开激活区 → 关闭窗口（仅当无内容时）
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
