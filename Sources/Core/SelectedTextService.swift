import Cocoa

/// Selected-text retrieval service
///
/// Strategy (by priority):
/// 1. AX Accessibility API — read the selected-text attribute of the focused element in the given app directly; fastest and side-effect-free
/// 2. Clipboard simulation — fallback (for browsers etc. that don't support the AX selected-text attribute); simulates cmd+c via CGEvent
///
/// ⚠️ Both AX API and NSPasteboard must be called on the main thread (synchronous paths such as Carbon callbacks may call directly)
public enum SelectedTextService {
    /// Asynchronously get the current selected text of the given app
    /// - Parameter targetApp: Target app (usually the frontmost app recorded before the panel opens)
    /// - Returns: The selected text; returns nil on failure or when empty
    public static func getSelectedText(from targetApp: NSRunningApplication) async -> String? {
        // 1. AX fast path — no side effects
        if let text = _tryAXSelectedText(from: targetApp) {
            return text
        }

        // 2. Clipboard simulation — the side-effecting fallback
        return await _clipboardFallbackSelectedText()
    }

    // MARK: - AX

    /// Get selected text via the AX API (synchronous, must be called on the main thread)
    /// Suitable for the fast path: no side effects, only reads attributes.
    public static func tryAXSelectedText(from app: NSRunningApplication) -> String? {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &value)
            == .success,
            let focused = value
        else { return nil }
        let el = focused as! AXUIElement
        var selectedText: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selectedText)
            == .success,
            let text = selectedText as? String, !text.isEmpty
        else { return nil }
        return text
    }

    /// Internal private AX version (called by getSelectedText)
    private static func _tryAXSelectedText(from app: NSRunningApplication) -> String? {
        tryAXSelectedText(from: app)
    }

    // MARK: - Clipboard Fallback

    /// Get selected text via clipboard by simulating cmd+c (async polling, does not block the caller)
    /// Does not restore the original clipboard — leaves the selected content on the clipboard so the user can paste directly
    private static func _clipboardFallbackSelectedText() async -> String? {
        let pb = NSPasteboard.general

        // Clear the clipboard to prepare for the cmd+c write
        pb.clearContents()
        let postClearCount = pb.changeCount

        // Simulate cmd+c
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return nil }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Async poll waiting for the cmd+c write (up to ~120ms; via continuation, does not block the caller)
        return await withCheckedContinuation { continuation in
            _pollClipboard(
                pb, sinceChangeCount: postClearCount, remainingAttempts: 6, continuation: continuation,
            )
        }
    }

    /// Recursively poll clipboard changes (20ms interval, up to 6 times = 120ms)
    private static func _pollClipboard(
        _ pb: NSPasteboard, sinceChangeCount: Int,
        remainingAttempts: Int,
        continuation: CheckedContinuation<String?, Never>,
    ) {
        if pb.changeCount > sinceChangeCount {
            // Clipboard changed, read the text
            continuation.resume(returning: pb.string(forType: .string))
        } else if remainingAttempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                _pollClipboard(
                    pb, sinceChangeCount: sinceChangeCount,
                    remainingAttempts: remainingAttempts - 1,
                    continuation: continuation,
                )
            }
        } else {
            // Timed out, give up
            continuation.resume(returning: nil)
        }
    }
}
