import Cocoa

/// 选中文本获取服务
///
/// 策略（按优先级）：
/// 1. AX Accessibility API — 从指定 app 聚焦元素的选中文本属性直接读取，最快且无副作用
/// 2. 剪贴板模拟 — 兜底方案（浏览器等不支持 AX 选中文本的属性时），通过 CGEvent 模拟 cmd+c
///
/// ⚠️ AX API 和 NSPasteboard 都必须在主线程调用（Carbon 回调等同步路径可直接调用）
public enum SelectedTextService {
    /// 异步获取指定 app 的当前选中文本
    /// - Parameter targetApp: 目标 app（通常为面板打开前记录的前台 app）
    /// - Returns: 选中文本，获取失败或为空时返回 nil
    public static func getSelectedText(from targetApp: NSRunningApplication) async -> String? {
        // 1. AX 快速路径 — 无副作用
        if let text = _tryAXSelectedText(from: targetApp) {
            return text
        }

        // 2. 剪贴板模拟 — 有副作用的兜底
        return await _clipboardFallbackSelectedText()
    }

    // MARK: - AX

    /// 通过 AX API 获取选中文本（同步，必须在主线程调用）
    /// 适用于快速路径：无副作用，仅读取属性。
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

    /// 内部私有的 AX 版本（供 getSelectedText 调用）
    private static func _tryAXSelectedText(from app: NSRunningApplication) -> String? {
        tryAXSelectedText(from: app)
    }

    // MARK: - Clipboard Fallback

    /// 通过模拟 cmd+c 从剪贴板获取选中文本（异步轮询，不阻塞调用方）
    /// 不恢复原始剪贴板 — 让选中的内容留在剪贴板上，用户可直接粘贴
    private static func _clipboardFallbackSelectedText() async -> String? {
        let pb = NSPasteboard.general

        // 清空剪贴板，准备接收 cmd+c 写入
        pb.clearContents()
        let postClearCount = pb.changeCount

        // 模拟 cmd+c
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return nil }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // 异步轮询等待 cmd+c 写入（最多 ~120ms，通过 continuation 不阻塞调用方）
        return await withCheckedContinuation { continuation in
            _pollClipboard(
                pb, sinceChangeCount: postClearCount, remainingAttempts: 6, continuation: continuation,
            )
        }
    }

    /// 递归轮询剪贴板变化（每次间隔 20ms，最多 6 次 = 120ms）
    private static func _pollClipboard(
        _ pb: NSPasteboard, sinceChangeCount: Int,
        remainingAttempts: Int,
        continuation: CheckedContinuation<String?, Never>,
    ) {
        if pb.changeCount > sinceChangeCount {
            // 剪贴板已变化，读取文本
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
            // 超时，放弃
            continuation.resume(returning: nil)
        }
    }
}
