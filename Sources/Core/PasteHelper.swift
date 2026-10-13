import Cocoa

/// Schedules a Cmd+V paste for the target app.
/// When target is nil, polls waiting for focus to leave utility (every 20ms, up to 180ms) before pasting into the frontmost app.
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
        task.arguments = [
            "-e",
            "tell application \"System Events\" to keystroke \"v\" using command down",
        ]
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
