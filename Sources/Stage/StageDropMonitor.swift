import Cocoa

/// 全局拖拽监听器 — EventTap 驱动
///
/// 核心规则:
/// 1. 有暂存数据 → 窗口常驻显示（alpha=1.0）
/// 2. 无数据时拖拽 → 鼠标靠近窗口区域才显示，远离则隐藏
/// 3. 在窗口内松手 → 读 drag pasteboard 写入 StageManager
///
/// 不依赖 NSView 拖拽系统（nonactivatingPanel 窗口不收 drag 事件）
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var eventTap: CFMachPort?
    private var isDragging = false
    private var isInternalClick = false
    private var lastDragChangeCount: Int = -1

    private var isWindowVisible: Bool {
        stageWindow?.window?.isVisible ?? false
    }

    private init() {}

    public func start(with window: StageWindowController) {
        stageWindow = window
        // 已有数据 → 窗口常驻显示
        let items = (try? StageManager.shared.count()) ?? 0
        if items > 0 {
            window.show()
        }
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
            isInternalClick = isMouseInWindow(NSEvent.mouseLocation)

        case .leftMouseUp:
            isDragging = false
            let mouse = NSEvent.mouseLocation
            let inWindow = isMouseInWindow(mouse)
            let dragPb = NSPasteboard(name: .drag)
            let cc = dragPb.changeCount
            if inWindow && !isInternalClick, cc != lastDragChangeCount {
                lastDragChangeCount = cc
                processDrop()
            }
            isInternalClick = false
            // 无内容且鼠标不在窗口内 → 淡出
            let items = (try? StageManager.shared.count()) ?? 0
            if items == 0 && !isMouseInWindow(mouse) {
                stageWindow?.close()
            }

        case .leftMouseDragged:
            guard isDragging else { break }
            guard !isInternalClick else { break }
            let mouse = NSEvent.mouseLocation
            let items = (try? StageManager.shared.count()) ?? 0

            if items > 0 {
                // 有数据：常驻显示，确保可见
                if !isWindowVisible {
                    stageWindow?.show()
                }
            } else if isMouseInWindow(mouse) {
                // 无数据但拖拽到窗口区域：显示
                if !isWindowVisible {
                    stageWindow?.show()
                }
            } else {
                // 无数据且远离：隐藏
                if isWindowVisible {
                    stageWindow?.close()
                }
            }

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

        // URL（文件 + 链接）
        if let urls = dragPb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.map { $0.standardizedFileURL }.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
            let webURLs = urls.filter { !$0.standardizedFileURL.isFileURL }

            if fileURLs.count > 1 {
                try? StageManager.shared.addFiles(urls: fileURLs)
            } else {
                for url in fileURLs {
                    try? StageManager.shared.add(fileURL: url)
                }
            }
            for url in webURLs {
                try? StageManager.shared.add(url: url)
            }

            if !fileURLs.isEmpty || !webURLs.isEmpty {
                stageWindow?.reload()
                return
            }
        }

        // 图片（浏览器/截图 — 无文件 URL，只有原始数据）→ 写临时文件 → 统一为 fileURL
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png,
            .init("public.jpeg"), .init("public.heic")]
        for type in imageTypes {
            if let data = dragPb.data(forType: type) {
                let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache/utility/stage")
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                let filename = "stage_\(Int(Date().timeIntervalSince1970)).png"
                let fileURL = cacheDir.appendingPathComponent(filename)
                try? data.write(to: fileURL)
                try? StageManager.shared.add(fileURL: fileURL)
                stageWindow?.reload()
                return
            }
        }

        // 富文本 HTML（网页拖入）
        if let html = dragPb.string(forType: .html) {
            let id = UUID().uuidString
            let item = StageItem(type: "html", content: html.data(using: .utf8) ?? Data())
            try? AppDatabase.shared.dbQueue.write { db in try item.insert(db) }
            stageWindow?.reload()
            return
        }

        // 纯文本
        if let text = dragPb.string(forType: .string), !text.isEmpty {
            try? StageManager.shared.add(text: text)
            stageWindow?.reload()
            return
        }
    }
}
