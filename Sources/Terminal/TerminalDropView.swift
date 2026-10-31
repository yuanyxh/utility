import Cocoa
import SwiftTerm

/// Terminal that inserts shell-quoted file paths dropped from Finder.
final class TerminalDropView: LocalProcessTerminalView {
    private static let unsafeCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "'\"\\$`!*?[]{}()&;|<>#~^="))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder _: NSCoder) {
        nil
    }

    /// Reports sent per classic wheel notch; SwiftTerm forwards exactly one.
    private static let reportsPerNotch = 3
    private static let dragThreshold: CGFloat = 3
    private var scrollMonitor: Any?
    private var mouseReportingSuspended = false
    private var pendingDown: NSEvent?
    private var pendingDownPoint: NSPoint = .zero
    private var didDragSelect = false

    /// Clicking the grid takes keyboard focus back from the sidebar. A press is
    /// held back so drags can select text locally; a click with no drag is then
    /// replayed to the TUI, keeping its buttons and options usable.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pendingDown = event
        pendingDownPoint = event.locationInWindow
        didDragSelect = false
        if allowMouseReporting {
            allowMouseReporting = false
            mouseReportingSuspended = true
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !didDragSelect {
            let dx = event.locationInWindow.x - pendingDownPoint.x
            let dy = event.locationInWindow.y - pendingDownPoint.y
            didDragSelect = hypot(dx, dy) >= Self.dragThreshold
        }
        super.mouseDragged(with: event)
    }

    /// A double-click on punctuation selects nothing, and `copy` clears the
    /// pasteboard before writing; keep the previous contents so the TUI's own
    /// copy-on-select survives.
    override func copy(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        super.copy(sender)
        let length = pasteboard.string(forType: .string)?.count ?? -1
        debugLog("[Terminal] copy pasteboardLength=\(length)")
        if length == 0, let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let dragged = didDragSelect
        super.mouseUp(with: event)
        if mouseReportingSuspended {
            allowMouseReporting = true
            mouseReportingSuspended = false
        }
        // A plain click belongs to the TUI; only drags above threshold select.
        if !dragged, let down = pendingDown, allowMouseReporting {
            super.mouseDown(with: down)
            super.mouseUp(with: event)
        }
        pendingDown = nil
    }

    /// A fullscreen TUI scrolls one notch per mouse report and SwiftTerm
    /// sends exactly one per classic wheel event, which crawls. `scrollWheel`
    /// is not `open`, so a local monitor replays the event instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else {
            installScrollMonitor()
            return
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self, let window, event.window === window else { return event }
            // A press whose mouseUp was never delivered must not leave the
            // terminal unable to forward wheel events.
            if mouseReportingSuspended, NSEvent.pressedMouseButtons == 0 {
                allowMouseReporting = true
                mouseReportingSuspended = false
            }
            guard !event.hasPreciseScrollingDeltas else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            for _ in 0..<Self.reportsPerNotch {
                scrollWheel(with: event)
            }
            return nil
        }
    }

    /// NSResponder declares these but never implements them, so ⌘←/⌘→ sent
    /// through the responder chain is a no-op; forward to SwiftTerm's
    /// `doCommand`, which emits Home/End.
    override func moveToBeginningOfLine(_: Any?) {
        doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
    }

    override func moveToEndOfLine(_: Any?) {
        doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = fileURLs(from: sender).map(\.path)
        guard !paths.isEmpty, process != nil else { return false }
        let text = paths.map(shellPath).joined(separator: " ") + " "
        send(source: self, data: ArraySlice(Array(text.utf8)))
        window?.makeFirstResponder(self)
        return true
    }

    /// Quote only paths with shell-special characters.
    private func shellPath(_ path: String) -> String {
        path.unicodeScalars.contains(where: Self.unsafeCharacters.contains)
            ? TerminalShell.quote(path) : path
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options,
        )
        return (objects as? [NSURL])?.map { $0 as URL } ?? []
    }
}
