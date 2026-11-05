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
            guard let undo = responder.undoManager ?? NSApp.keyWindow?.undoManager else {
                debugLog("[Shortcut] undo manager missing responder=\(type(of: responder))")
                return event
            }
            let redo = flags.contains(.shift)
            // Leave the key to AppKit when there is nothing to undo; swallowing
            // it would make ⌘Z silently do nothing.
            guard redo ? undo.canRedo : undo.canUndo else { return event }
            let before = (responder as? NSTextView)?.string.count ?? -1
            if redo { undo.redo() } else { undo.undo() }
            let after = (responder as? NSTextView)?.string.count ?? -1
            debugLog(
                "[Shortcut] undo responder=\(type(of: responder)) len=\(before)->\(after)",
            )
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
