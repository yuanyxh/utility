import Carbon
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
        if flags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c"
        {
            let responder = NSApp.keyWindow?.firstResponder
            debugLog(
                "[Shortcut] copy-key flags=\(flags.rawValue) keyWindow=\(NSApp.keyWindow != nil) responder=\(responder.map { "\(type(of: $0))" } ?? "nil") control=\(flags.contains(.control)) option=\(flags.contains(.option))",
            )
        }
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              let responder = NSApp.keyWindow?.firstResponder
        else { return event }

        // No menu owns ⌘←/⌘→, so the line-edge commands never reach the
        // responder chain; route them like the menu equivalents would. Checked
        // before `charactersIgnoringModifiers`, which can be nil under IMEs.
        if event.keyCode == UInt16(kVK_LeftArrow) || event.keyCode == UInt16(kVK_RightArrow) {
            return routeLineEdge(event, to: responder) ? nil : event
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        switch key {
        case "z":
            guard let undo = responder.undoManager else { return event }
            if flags.contains(.shift) { undo.redo() } else { undo.undo() }
            return nil
        case "x":
            return send(#selector(NSText.cut(_:)), to: responder) ? nil : event
        case "c":
            let handled = send(#selector(NSText.copy(_:)), to: responder)
            debugLog("[Shortcut] copy handled=\(handled) responder=\(type(of: responder))")
            return handled ? nil : event
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

    /// ⌘←/⌘→ jump to the line edges; ⇧ extends the selection. Terminals handle
    /// these selectors through `doCommand(by:)`, text views natively.
    private static func routeLineEdge(_ event: NSEvent, to responder: NSResponder) -> Bool {
        let toStart = event.keyCode == UInt16(kVK_LeftArrow)
        let extends = event.modifierFlags.contains(.shift)
        let selector: Selector = if extends {
            toStart
                ? #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:))
                : #selector(NSResponder.moveToEndOfLineAndModifySelection(_:))
        } else {
            toStart
                ? #selector(NSResponder.moveToBeginningOfLine(_:))
                : #selector(NSResponder.moveToEndOfLine(_:))
        }
        guard responder.responds(to: selector) else {
            debugLog("[Shortcut] line-edge unhandled responder=\(type(of: responder))")
            return false
        }
        return send(selector, to: responder)
    }
}
