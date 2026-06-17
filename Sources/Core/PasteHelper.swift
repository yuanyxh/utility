import Cocoa

/// 用 AX 值注入 + CGEventPost 兜底的方式粘贴文本到目标 app。
/// AX 注入对网页输入框可靠（绕过 Blink 渲染进程焦点就位时序问题），
/// 模拟按键对 native 控件有效，但对网页内容有竞态。
func pasteTextWithAXFallback(text: String, to target: NSRunningApplication, logPrefix: String) {
    var attempts = 0
    let maxAttempts = 50 // 50 × 10ms = 500ms max

    func tryInject() {
        attempts += 1
        guard attempts <= maxAttempts else {
            debugLog("[utility] \(logPrefix) AX inject: timeout \(maxAttempts) attempts, fallback Cmd+V")
            sendCmdV()
            return
        }

        let appRef = AXUIElementCreateApplication(target.processIdentifier)
        var focused: CFTypeRef?
        let getResult = AXUIElementCopyAttributeValue(appRef,
            kAXFocusedUIElementAttribute as CFString, &focused)

        guard getResult == .success, let focusedEl = focused else {
            // 焦点元素尚未就绪，10ms 后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { tryInject() }
            return
        }

        let el = focusedEl as! AXUIElement

        // 尝试直接写值（对网页 <input>/<textarea> 和原生 NSTextField 都有效）
        let setResult = AXUIElementSetAttributeValue(el,
            kAXValueAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            debugLog("[utility] \(logPrefix) AX inject: SUCCESS at attempt \(attempts)")
            return
        }

        debugLog("[utility] \(logPrefix) AX inject: set failed err=\(setResult), fallback Cmd+V")
        sendCmdV()
    }

    func sendCmdV() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            debugLog("[utility] \(logPrefix) Cmd+V via System Events")
            let script = NSAppleScript(source:
                "tell application \"System Events\" to keystroke \"v\" using command down")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let err = error {
                debugLog("[utility] \(logPrefix) System Events failed: \(err), CGEventPost fallback")
                let src = CGEventSource(stateID: .combinedSessionState)
                if let kd = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
                   let ku = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
                    kd.flags = .maskCommand
                    ku.flags = .maskCommand
                    kd.post(tap: .cghidEventTap)
                    ku.post(tap: .cghidEventTap)
                    debugLog("[utility] \(logPrefix) CGEventPost sent")
                }
            } else {
                debugLog("[utility] \(logPrefix) System Events Cmd+V sent OK")
            }
        }
    }

    tryInject()
}
