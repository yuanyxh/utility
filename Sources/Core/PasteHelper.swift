import Cocoa

/// 浏览器 bundle ID 集合 — 这些 app 的网页内容需要等 Blink 渲染进程焦点就位（~50-120ms）
private let browserBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.apple.Safari",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.operasoftware.Opera",
    "com.brave.Browser",
    "company.thebrowser.Browser", // Arc
]

/// 为目标 app 调度 Cmd+V 粘贴。
/// 浏览器：120ms 单次（等渲染进程焦点就位），叠加 System Events + CGEventPost 双路。
/// 原生 app：50ms 单次。
func schedulePaste(to target: NSRunningApplication, logPrefix: String) {
    let isBrowser = browserBundleIDs.contains(target.bundleIdentifier ?? "")
    let delay: TimeInterval = isBrowser ? 0.12 : 0.05

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        debugLog("[utility] \(logPrefix) paste at \(delay)s\(isBrowser ? " (browser, dual-path)" : "")")
        // System Events keystroke
        let script = NSAppleScript(source:
            "tell application \"System Events\" to keystroke \"v\" using command down")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let err = error {
            debugLog("[utility] \(logPrefix) System Events error: \(err)")
        }
        // CGEventPost 兜底（浏览器双路并进，提高命中率）
        if isBrowser {
            let src = CGEventSource(stateID: .combinedSessionState)
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
               let ku = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
                kd.flags = .maskCommand
                ku.flags = .maskCommand
                kd.post(tap: .cghidEventTap)
                ku.post(tap: .cghidEventTap)
                debugLog("[utility] \(logPrefix) CGEventPost sent (browser dual-path)")
            }
        }
    }
}
