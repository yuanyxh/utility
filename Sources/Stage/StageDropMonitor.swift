import Cocoa

/// 全局拖拽监听器 — 事件驱动，无轮询
/// 窗口始终在线（alpha=0.01），拖拽开始时拉至完全可见，松手后若仍无内容则淡出
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var eventTap: CFMachPort?
    private var isDragging = false

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
            print("[StageDrop] EventTap installed OK")
        } else {
            print("[StageDrop] EventTap FAILED — no Accessibility permission?")
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .leftMouseDown:
            isDragging = true
            // 拖拽开始 → 窗口完全可见
            stageWindow?.show()
            print("[StageDrop] Drag started, window shown")

        case .leftMouseUp:
            isDragging = false
            // 松手后，如果无内容且鼠标不在窗口区 → 淡出
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let items = (try? StageManager.shared.count()) ?? 0
                if items > 0 { return }  // 有内容，保持可见

                let mouse = NSEvent.mouseLocation
                if let frame = self.stageWindow?.window?.frame {
                    let inWindow = NSRect(x: frame.minX - 20, y: frame.minY - 20,
                                          width: frame.width + 40, height: frame.height + 40)
                        .contains(mouse)
                    if !inWindow {
                        self.stageWindow?.close()
                        print("[StageDrop] No items, mouse outside, faded out")
                    }
                }
            }

        case .leftMouseDragged:
            guard isDragging else { break }
            // 拖拽中，确保窗口可见（已有内容时可能已经可见）
            if stageWindow?.window?.alphaValue != 1.0 {
                stageWindow?.show()
            }

            // 远离窗口且无内容 → 淡出
            let mouse = NSEvent.mouseLocation
            let windowFrame = stageWindow?.window?.frame ?? .zero
            let hitZone = NSRect(x: windowFrame.minX - 20, y: windowFrame.minY - 20,
                                 width: windowFrame.width + 40, height: windowFrame.height + 40)
            if !hitZone.contains(mouse) {
                let items = (try? StageManager.shared.count()) ?? 0
                if items == 0 {
                    stageWindow?.close()
                    print("[StageDrop] Drag away from window, no items, faded out")
                }
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
