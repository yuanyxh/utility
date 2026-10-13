import Cocoa

/// Global drag monitor — EventTap driven
///
/// Core rules:
/// 1. Has stage data → window stays visible (alpha=1.0)
/// 2. Dragging with no data → show only when the mouse is near the window area, hide when far away
/// 3. Release inside the window → read the drag pasteboard and write to StageManager
///
/// Does not rely on the NSView drag system (nonactivatingPanel windows do not receive drag events)
public final class StageDropMonitor {
    public static let shared = StageDropMonitor()
    private weak var stageWindow: StageWindowController?
    private var eventTap: CFMachPort?
    private var isDragging = false
    private var isInternalClick = false
    private var dragCCAtMouseDown: Int = -1
    /// Pasteboard read throttle — returns the last cached result within 100ms to avoid blocking the system event pipeline
    private var lastPasteboardCheck: TimeInterval = 0
    private var lastPasteboardResult: Bool = false

    private var isWindowVisible: Bool {
        stageWindow?.window?.isVisible ?? false
    }

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
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let ctrl = Unmanaged<StageDropMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return ctrl.handleEvent(type: type, event: event)
        }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.leftMouseUp.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: ptr,
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
            isInternalClick = isMouseInWindow(NSEvent.mouseLocation)

        case .leftMouseUp:
            isDragging = false
            let mouse = NSEvent.mouseLocation
            let inWindow = isMouseInWindow(mouse)
            let newChangeCount = NSPasteboard(name: .drag).changeCount
            let hasContent = newChangeCount != dragCCAtMouseDown && dragPasteboardHasContent()

            dragCCAtMouseDown = newChangeCount

            if (isInternalClick && inWindow) || (inWindow && !hasContent) || !inWindow {
                break
            }

            processDrop()

            isInternalClick = false

        case .leftMouseDragged:
            guard isDragging else { break }
            guard !isInternalClick else { break }

            let items = (try? StageManager.shared.count()) ?? 0
            let mouse = NSEvent.mouseLocation
            let inWindow = isMouseInWindow(mouse)
            let newChangeCount = NSPasteboard(name: .drag).changeCount
            let hasContent = newChangeCount != dragCCAtMouseDown && dragPasteboardHasContent()

            if items > 0 || (hasContent && inWindow) {
                if !isWindowVisible {
                    stageWindow?.show()
                }
            } else {
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

    /// Content-type detection fully aligned with processDrop, side-effect free
    private func dragPasteboardHasContent() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPasteboardCheck > 0.1 else { return lastPasteboardResult }
        lastPasteboardCheck = now
        let pb = NSPasteboard(name: .drag)
        // URL (same filter logic as processDrop)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.map(\.standardizedFileURL).filter {
                $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
            }
            let webURLs = urls.filter { !$0.standardizedFileURL.isFileURL }
            if !fileURLs.isEmpty || !webURLs.isEmpty {
                lastPasteboardResult = true
                return true
            }
        }
        // Image
        for type in PasteboardImageTypes.all {
            if pb.data(forType: type) != nil {
                lastPasteboardResult = true
                return true
            }
        }
        // HTML
        if pb.string(forType: .html) != nil {
            lastPasteboardResult = true
            return true
        }
        // Plain text
        if let text = pb.string(forType: .string), !text.isEmpty {
            lastPasteboardResult = true
            return true
        }

        lastPasteboardResult = false
        return false
    }

    private func isMouseInWindow(_ mouse: NSPoint) -> Bool {
        guard let frame = stageWindow?.window?.frame else { return false }
        return NSRect(
            x: frame.minX - 20, y: frame.minY - 20,
            width: frame.width + 40, height: frame.height + 40,
        )
        .contains(mouse)
    }

    private func processDrop() {
        let dragPb = NSPasteboard(name: .drag)

        // URL (file + link)
        if let urls = dragPb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty
        {
            let fileURLs = urls.map(\.standardizedFileURL).filter {
                $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
            }
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

        // Image (browser/screenshot — no file URL, only raw data) → write temp file → unify as fileURL
        for type in PasteboardImageTypes.all {
            if let data = dragPb.data(forType: type) {
                let cacheDir = AppPaths.stageCacheDir
                let filename = "stage_\(Int(Date().timeIntervalSince1970)).png"
                let fileURL = cacheDir.appendingPathComponent(filename)
                try? data.write(to: fileURL)
                try? StageManager.shared.add(fileURL: fileURL)
                stageWindow?.reload()
                return
            }
        }

        // Rich-text HTML (dragged in from a web page)
        if let html = dragPb.string(forType: .html) {
            let item = StageItem(type: "html", content: html.data(using: .utf8) ?? Data())
            try? AppDatabase.shared.dbQueue.write { db in try item.insert(db) }
            stageWindow?.reload()
            return
        }

        // Plain text
        if let text = dragPb.string(forType: .string), !text.isEmpty {
            try? StageManager.shared.add(text: text)
            stageWindow?.reload()
            return
        }
    }
}
