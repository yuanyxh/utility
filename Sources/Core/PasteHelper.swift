import Cocoa

/// 为目标 app 调度 Cmd+V 粘贴。
/// target 为 nil 时轮询等待焦点离开 utility（每 20ms，最长 180ms）再粘贴到前台 app。
func schedulePaste(attempts: Int) {
    schedulePasteWhenFrontmostChange(attempts: attempts)
}

private func schedulePasteWhenFrontmostChange(attempts: Int) {
    guard attempts > 0 else {
        doPaste()
        return
    }

    if NSApplication.shared.keyWindow == nil {
        doPaste()
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        schedulePasteWhenFrontmostChange(attempts: attempts - 1)
    }
}

private func doPaste() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e",
            "tell application \"System Events\" to keystroke \"v\" using command down"]
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.launch()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            cgEventPaste()
        }
    }
}

func cgEventPaste() {
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
