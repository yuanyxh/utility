import Cocoa

/// 全局拖拽监听器 — EventTap 驱动
/// 窗口始终在线（alpha=0.01），拖拽开始时拉至完全可见，
/// 松手时若鼠标在窗口内则读取 drag pasteboard 直接处理 drop，
/// 不依赖 NSView 拖拽系统（nonactivatingPanel 窗口不收 drag 事件）
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var eventTap: CFMachPort?
    private var isDragging = false
    private var windowShown = false

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
        } else {
            Log.debug("[StageDrop] EventTap FAILED — need Accessibility permission")
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .leftMouseDown:
            isDragging = true
            if !windowShown {
                stageWindow?.show()
                windowShown = true
            }

        case .leftMouseUp:
            isDragging = false
            windowShown = false
            let mouse = NSEvent.mouseLocation
            if isMouseInWindow(mouse) {
                processDrop()
            }
            let items = (try? StageManager.shared.count()) ?? 0
            if items == 0 {
                stageWindow?.close()
            }

        case .leftMouseDragged:
            break

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Helpers

    private func isMouseInWindow(_ mouse: NSPoint) -> Bool {
        guard let frame = stageWindow?.window?.frame else { return false }
        return NSRect(x: frame.minX - 20, y: frame.minY - 20,
                      width: frame.width + 40, height: frame.height + 40)
            .contains(mouse)
    }

    private func processDrop() {
        let dragPb = NSPasteboard(name: .drag)

        // 文件
        if let urls = dragPb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let fileURL = url.standardizedFileURL
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try? StageManager.shared.add(fileURL: fileURL)
                }
            }
            if !urls.isEmpty {
                stageWindow?.reload()
                return
            }
        }

        // 文本
        if let text = dragPb.string(forType: .string), !text.isEmpty {
            try? StageManager.shared.add(text: text)
            stageWindow?.reload()
            return
        }

        // 图片
        for type in [NSPasteboard.PasteboardType.tiff, .png,
                     NSPasteboard.PasteboardType("public.jpeg"),
                     NSPasteboard.PasteboardType("public.heic")] {
            if let data = dragPb.data(forType: type) {
                try? StageManager.shared.add(imageData: data)
                stageWindow?.reload()
                return
            }
        }
    }
}
