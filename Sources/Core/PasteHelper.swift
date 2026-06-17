import Cocoa

/// 发送 Cmd+V 按键到当前前台 app。
/// 浏览器目标需更长延迟，等 Blink 渲染进程焦点就位（~50-200ms）。
/// 原生 app 50ms 足够。
func sendPasteCmdV(delay: TimeInterval, logPrefix: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        debugLog("[utility] \(logPrefix) paste: Cmd+V at delay=\(delay)")
        // System Events keystroke 优先（对 Chrome 网页有效）
        let script = NSAppleScript(source:
            "tell application \"System Events\" to keystroke \"v\" using command down")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let err = error {
            debugLog("[utility] \(logPrefix) paste: System Events failed: \(err), CGEventPost fallback")
            let src = CGEventSource(stateID: .combinedSessionState)
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
               let ku = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
                kd.flags = .maskCommand
                ku.flags = .maskCommand
                kd.post(tap: .cghidEventTap)
                ku.post(tap: .cghidEventTap)
                debugLog("[utility] \(logPrefix) paste: CGEventPost sent")
            }
        } else {
            debugLog("[utility] \(logPrefix) paste: System Events Cmd+V sent OK")
        }
    }
}

/// 浏览器 bundle ID 集合 — 这些 app 的网页内容需要更长延迟等渲染进程
private let browserBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.apple.Safari",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.operasoftware.Opera",
    "com.brave.Browser",
    "company.thebrowser.Browser", // Arc
]

/// 为目标 app 选择合适的粘贴延迟
/// 浏览器：300ms（Blink 渲染进程焦点就位需 50-200ms + 安全余量）
/// 其他：50ms（原生控件瞬间就位）
func pasteDelay(for bundleID: String?) -> TimeInterval {
    if let bid = bundleID, browserBundleIDs.contains(bid) {
        return 0.30
    }
    return 0.05
}
