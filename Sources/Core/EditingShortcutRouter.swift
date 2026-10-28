import Cocoa

/// No main menu means ⌘Z/⌘X/⌘C/⌘V/⌘A never reach menu equivalents.
/// Route them to the first responder's standard actions; else pass through.
@MainActor
enum EditingShortcutRouter {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              let responder = NSApp.keyWindow?.firstResponder,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return event }

        switch key {
        case "z":
            guard let undo = responder.undoManager else { return event }
            if flags.contains(.shift) { undo.redo() } else { undo.undo() }
            return nil
        case "x":
            return send(#selector(NSText.cut(_:)), to: responder) ? nil : event
        case "c":
            return send(#selector(NSText.copy(_:)), to: responder) ? nil : event
        case "v":
            return send(#selector(NSText.paste(_:)), to: responder) ? nil : event
        case "a":
            return send(#selector(NSResponder.selectAll(_:)), to: responder) ? nil : event
        default:
            return event
        }
    }

    private static func send(_ selector: Selector, to responder: NSResponder) -> Bool {
        NSApp.sendAction(selector, to: responder, from: nil)
    }
}
