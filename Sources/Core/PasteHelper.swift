import Cocoa

/// 浏览器 bundle ID 集合 — 这些 app 的网页内容需要等 Blink 渲染进程焦点就位
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
/// 浏览器：30ms 间隔轮询重试，最多 120ms（4 次），末次叠加 CGEventPost 兜底。
/// 原生 app：单次 50ms。
func schedulePaste(to target: NSRunningApplication, logPrefix: String) {
    let isBrowser = browserBundleIDs.contains(target.bundleIdentifier ?? "")

    if isBrowser {
        let delays: [TimeInterval] = [0.03, 0.06, 0.09, 0.12]
        for (i, delay) in delays.enumerated() {
            let final = i == delays.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                debugLog("[utility] \(logPrefix) browser paste \(i+1)/\(delays.count) at \(delay)s\(final ? " +CGEvent" : "")")
                sendKeystrokeCmdV(logPrefix: logPrefix)
                if final {
                    sendCGEventCmdV(logPrefix: logPrefix)
                }
            }
        }
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            debugLog("[utility] \(logPrefix) native paste at 0.05s")
            sendKeystrokeCmdV(logPrefix: logPrefix)
        }
    }
}

// MARK: - Internal

private func sendKeystrokeCmdV(logPrefix: String) {
    let script = NSAppleScript(source:
        "tell application \"System Events\" to keystroke \"v\" using command down")
    var error: NSDictionary?
    script?.executeAndReturnError(&error)
    if let err = error {
        debugLog("[utility] \(logPrefix) System Events error: \(err)")
    }
}

private func sendCGEventCmdV(logPrefix: String) {
    let src = CGEventSource(stateID: .combinedSessionState)
    guard let kd = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
          let ku = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
        debugLog("[utility] \(logPrefix) CGEventPost create failed")
        return
    }
    kd.flags = .maskCommand
    ku.flags = .maskCommand
    kd.post(tap: .cghidEventTap)
    ku.post(tap: .cghidEventTap)
    debugLog("[utility] \(logPrefix) CGEventPost sent")
}
