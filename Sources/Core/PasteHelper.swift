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
/// 浏览器：120ms（等渲染进程焦点就位），通过 osascript 子进程执行 keystroke。
/// 原生 app：50ms。
func schedulePaste(to target: NSRunningApplication) {
    let isBrowser = browserBundleIDs.contains(target.bundleIdentifier ?? "")
    let delay: TimeInterval = isBrowser ? 0.12 : 0.05

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e",
            "tell application \"System Events\" to keystroke \"v\" using command down"]
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.launch()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let src = CGEventSource(stateID: .combinedSessionState)
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
               let ku = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            {
                kd.flags = .maskCommand
                ku.flags = .maskCommand
                kd.post(tap: .cghidEventTap)
                ku.post(tap: .cghidEventTap)
            }
        }
    }
}
