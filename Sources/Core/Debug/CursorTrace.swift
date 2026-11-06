#if DEBUG
    import AppKit

    /// Debug-only instrument that records which code path sets the shared cursor.
    enum CursorTrace {
        private static var installed = false

        static func installIfRequested() {
            guard !installed,
                ProcessInfo.processInfo.environment["UTILITY_CURSOR_TRACE"] == "1"
            else { return }
            installed = true
            guard
                let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set)),
                let replacement = class_getInstanceMethod(
                    NSCursor.self, #selector(NSCursor.tracedSet),
                )
            else { return }
            method_exchangeImplementations(original, replacement)
            debugLog("[Cursor] trace installed")
        }
    }

    extension NSCursor {
        @objc fileprivate func tracedSet() {
            let frames = Thread.callStackSymbols.dropFirst().prefix(6).joined(separator: " <- ")
            debugLog("[Cursor] set by \(frames)")
            tracedSet()
        }
    }
#endif
