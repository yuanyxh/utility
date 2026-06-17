import Cocoa

/// 翻译面板 — 26 语种支持
/// 上方原文 + 左侧语言选择，下方译文 + 右侧语言选择
/// enter 翻译，cmd+enter 换行，esc 关闭，ctrl+enter 粘贴译文
/// 自定义面板 — 用 performKeyEquivalent 处理快捷键
private final class TranslationTextView: NSTextView {
    weak var controller: TranslationPanelController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53: // esc
            controller?.close()
            return true
        case 36: // return / enter
            if flags == .command {
                // cmd+enter → 翻译（允许取消旧翻译重新开始）
                controller?.performTranslation()
                return true
            }
            if flags == .shift {
                // shift+enter → 换行
                insertNewline(nil)
                return true
            }
            if !flags.contains(.command) && !flags.contains(.control) {
                // 纯 Enter → 粘贴并关闭（翻译中忽略）
                if controller?.isTranslating == true { return true }
                controller?.pasteTranslation()
                controller?.close()
                return true
            }
            return false
        default:
            break
        }
        // cmd+c/x/v/a/z 交给 NSTextView 原生处理
        return false
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36, !flags.contains(.command), !flags.contains(.control), !flags.contains(.shift) {
            if controller?.isTranslating == true { return }
            controller?.pasteTranslation()
            controller?.close()
            return
        }
        super.keyDown(with: event)
    }
}

/// 自定义 NSPanel：拦截 cmd+c/x/v/a/z 等编辑快捷键交给第一响应者
private final class TranslationPanel: NSPanel {
    weak var controller: TranslationPanelController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.keyCode {
            case 8:  // c
                if let textView = firstResponder as? NSTextView {
                    textView.copy(nil)
                    return true
                }
            case 7:  // x
                if let textView = firstResponder as? NSTextView, textView.isEditable {
                    textView.cut(nil)
                    return true
                }
            case 9:  // v
                if let textView = firstResponder as? NSTextView, textView.isEditable {
                    textView.paste(nil)
                    return true
                }
            case 0:  // a
                if let textView = firstResponder as? NSTextView {
                    textView.selectAll(nil)
                    return true
                }
            case 6:  // z
                if let textView = firstResponder as? NSTextView, textView.isEditable {
                    textView.undoManager?.undo()
                    return true
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

public final class TranslationPanelController: NSWindowController {
    private let sourceTextView = TranslationTextView()
    private let targetTextView = NSTextView()
    private let sourceLangPopup = NSPopUpButton()
    private let targetLangPopup = NSPopUpButton()
    private let scrollViewSource = NSScrollView()
    private let scrollViewTarget = NSScrollView()

    /// 下面板遮罩层
    private let overlay = TargetOverlayView()

    /// 当前翻译任务（用于取消）
    var currentTask: URLSessionTask?
    /// 是否有正在运行的翻译
    var isTranslating: Bool { currentTask != nil }
    /// 翻译序列号（用于判断任务是否已过期）
    private var translationSeq: UInt = 0

    /// 面板打开前的前台 app（粘贴时恢复到该 app）
    var previousFrontmostApp: NSRunningApplication?

    /// 26 种语言（按使用量排序）
    private let languages: [(code: String, name: String)] = [
        ("auto", "自动检测"),
        ("zh", "中文"), ("en", "英文"), ("es", "西班牙文"), ("hi", "印地文"),
        ("ar", "阿拉伯文"), ("bn", "孟加拉文"), ("pt", "葡萄牙文"), ("ru", "俄文"),
        ("ja", "日文"), ("pa", "旁遮普文"), ("de", "德文"), ("jv", "爪哇文"),
        ("ko", "韩文"), ("fr", "法文"), ("te", "泰卢固文"), ("mr", "马拉地文"),
        ("ta", "泰米尔文"), ("ur", "乌尔都文"), ("vi", "越南文"), ("it", "意大利文"),
        ("th", "泰文"), ("ms", "马来文"), ("tr", "土耳其文"),
        ("nl", "荷兰文"), ("pl", "波兰文"), ("uk", "乌克兰文"),
    ]

    public init() {
        let panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                                     styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        panel.level = NSWindow.Level.floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.controller = self
        sourceTextView.controller = self
        setupUI()
        setupDeactivateObserver()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        guard let panel = window else { return }
        let content = panel.contentView!

        // ---- 原文区 ----
        let sourceLabel = NSTextField(labelWithString: "原文")
        sourceLabel.font = NSFont.boldSystemFont(ofSize: 12)

        sourceLangPopup.target = self
        sourceLangPopup.action = #selector(sourceLangChanged)
        setupLanguagePopups()

        let sourceSpacer = NSView()
        sourceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sourceTopRow = NSStackView(views: [sourceLabel, sourceSpacer, sourceLangPopup])
        sourceTopRow.orientation = .horizontal
        sourceTopRow.alignment = .firstBaseline

        sourceTextView.isEditable = true
        sourceTextView.isRichText = false
        sourceTextView.font = NSFont.systemFont(ofSize: 13)
        sourceTextView.textContainerInset = NSSize(width: 6, height: 6)

        scrollViewSource.wantsLayer = true
        scrollViewSource.canDrawSubviewsIntoLayer = true
        scrollViewSource.layer?.borderWidth = 0.5
        scrollViewSource.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollViewSource.layer?.cornerRadius = 4
        scrollViewSource.documentView = sourceTextView
        scrollViewSource.hasVerticalScroller = true
        scrollViewSource.borderType = .noBorder
        scrollViewSource.scrollerStyle = .overlay
        scrollViewSource.autohidesScrollers = true
        scrollViewSource.verticalScroller?.controlSize = .small
        scrollViewSource.translatesAutoresizingMaskIntoConstraints = false

        let sourceSection = NSStackView(views: [sourceTopRow, scrollViewSource])
        sourceSection.orientation = .vertical
        sourceSection.spacing = 4
        sourceSection.translatesAutoresizingMaskIntoConstraints = false

        // ---- 译文区 ----
        let targetLabel = NSTextField(labelWithString: "译文")
        targetLabel.font = NSFont.boldSystemFont(ofSize: 12)

        targetLangPopup.target = self
        targetLangPopup.action = #selector(targetLangChanged)

        let targetSpacer = NSView()
        targetSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let targetTopRow = NSStackView(views: [targetLabel, targetSpacer, targetLangPopup])
        targetTopRow.orientation = .horizontal
        targetTopRow.alignment = .firstBaseline

        targetTextView.isEditable = false
        targetTextView.isRichText = false
        targetTextView.font = NSFont.systemFont(ofSize: 13)
        targetTextView.textContainerInset = NSSize(width: 6, height: 6)

        scrollViewTarget.wantsLayer = true
        scrollViewTarget.canDrawSubviewsIntoLayer = true
        scrollViewTarget.layer?.borderWidth = 0.5
        scrollViewTarget.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollViewTarget.layer?.cornerRadius = 4
        scrollViewTarget.documentView = targetTextView
        scrollViewTarget.hasVerticalScroller = true
        scrollViewTarget.borderType = .noBorder
        scrollViewTarget.scrollerStyle = .overlay
        scrollViewTarget.autohidesScrollers = true
        scrollViewTarget.verticalScroller?.controlSize = .small
        scrollViewTarget.translatesAutoresizingMaskIntoConstraints = false

        let targetSection = NSStackView(views: [targetTopRow, scrollViewTarget])
        targetSection.orientation = .vertical
        targetSection.spacing = 4
        targetSection.translatesAutoresizingMaskIntoConstraints = false

        // ---- 遮罩层 ----
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true

        // ---- 布局 ----
        content.addSubview(sourceSection)
        content.addSubview(targetSection)
        content.addSubview(overlay)

        let padding: CGFloat = 12
        let topPadding: CGFloat = 44

        NSLayoutConstraint.activate([
            sourceSection.topAnchor.constraint(equalTo: content.topAnchor, constant: topPadding),
            sourceSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            sourceSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),

            targetSection.topAnchor.constraint(equalTo: sourceSection.bottomAnchor, constant: 14),
            targetSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            targetSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            targetSection.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding),

            scrollViewSource.heightAnchor.constraint(equalTo: scrollViewTarget.heightAnchor),

            // 遮罩覆盖下面板区域（缩进 1pt 不挡住边框）
            overlay.topAnchor.constraint(equalTo: scrollViewTarget.topAnchor, constant: 1),
            overlay.leadingAnchor.constraint(equalTo: scrollViewTarget.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scrollViewTarget.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: scrollViewTarget.bottomAnchor, constant: -1),
        ])

        // 拖动停止时记忆位置
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition),
            name: NSWindow.didMoveNotification, object: panel
        )
    }

    @objc private func savePosition() {
        guard let origin = window?.frame.origin else { return }
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "translation_panel_origin")
    }

    /// 失焦自动关闭
    private func setupDeactivateObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(close),
            name: NSWindow.didResignKeyNotification, object: window
        )
    }

    // MARK: - Languages

    private func setupLanguagePopups() {
        for (code, name) in languages {
            sourceLangPopup.addItem(withTitle: name)
            sourceLangPopup.lastItem?.representedObject = code
            targetLangPopup.addItem(withTitle: name)
            targetLangPopup.lastItem?.representedObject = code
        }
        resetLanguageSelection()
    }

    private func resetLanguageSelection() {
        sourceLangPopup.selectItem(at: 0) // auto
        let config = ConfigManager.shared.config.translation
        if let idx = languages.firstIndex(where: { $0.code == config.targetLang }) {
            targetLangPopup.selectItem(at: idx)
        } else {
            targetLangPopup.selectItem(at: 0) // auto
        }
    }

    // MARK: - Language Change

    @objc private func sourceLangChanged(_ sender: Any) {
        guard !sourceTextView.string.isEmpty else { return }
        startTranslation(text: sourceTextView.string)
    }

    @objc private func targetLangChanged(_ sender: Any) {
        guard !sourceTextView.string.isEmpty else { return }
        startTranslation(text: sourceTextView.string)
    }

    // MARK: - Key Events

    // MARK: - Translation

    fileprivate func performTranslation() {
        let text = sourceTextView.string
        startTranslation(text: text)
    }

    // MARK: - Paste Translation

    fileprivate func pasteTranslation() {
        let text = targetTextView.string
        guard !text.isEmpty else { return }
        guard !overlay.isVisible || overlay.mode == .error else { return }

        // 先把译文写入粘贴板
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 记录目标 app（面板打开前的前台 app，而非当前自己）
        guard let target = previousFrontmostApp ?? NSWorkspace.shared.frontmostApplication else {
            window?.orderOut(nil)
            NSApplication.shared.hide(nil)
            return
        }

        // 隐藏面板，触发 app 切换
        window?.orderOut(nil)
        NSApplication.shared.hide(nil)

        // 轮询目标 app 的焦点元素，就绪后发 cmd+v（最多 100 次 ≈ 800ms）
        var attempts = 0
        func pollFocus(for app: NSRunningApplication) {
            attempts += 1
            guard attempts < 100 else { return } // 超时放弃
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            var focused: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focused)
            if result == .success, focused != nil {
                // 焦点就绪，发 cmd+v
                let source = CGEventSource(stateID: .combinedSessionState)
                guard let kd = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let ku = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
                kd.flags = .maskCommand
                ku.flags = .maskCommand
                kd.post(tap: .cghidEventTap)
                ku.post(tap: .cghidEventTap)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                pollFocus(for: app)
            }
        }
        pollFocus(for: target)
    }

    // MARK: - Show / Close

    /// 面板是否正在显示
    var isPanelVisible: Bool {
        window?.isVisible ?? false
    }

    /// 面板已显示时：填入选中文本并触发翻译（不移动面板位置）
    func fillAndTranslate(_ text: String) {
        guard !text.isEmpty else { return }
        sourceTextView.string = text
        targetTextView.string = ""
        overlay.hide()
        resetLanguageSelection()
        sourceTextView.scrollToEndOfDocument(nil)
        startTranslation(text: text)
    }

    /// 回退定位：鼠标左下方
    private func fallbackPosition() {
        let mouse = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero
        frame.origin.x = mouse.x - 310
        frame.origin.y = mouse.y - frame.height + 30
        window?.setFrame(frame, display: true)
    }

// MARK: - Show / Close
    /// 回调方式触发翻译
    func startTranslation(text: String) {
        // 取消旧任务，序列号防止旧回调干扰
        currentTask?.cancel()
        currentTask = nil
        let seq = translationSeq + 1
        translationSeq = seq

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let config = ConfigManager.shared.config
        guard !config.ai.apiKey.isEmpty else {
            overlay.showError("未配置 AI API Key")
            return
        }

        targetTextView.string = ""
        overlay.showLoading()
        let sourceCode = sourceLangPopup.selectedItem?.representedObject as? String ?? "auto"
        let targetCode = targetLangPopup.selectedItem?.representedObject as? String ?? "zh"
        currentTask = Translator.shared.translate(
            text: text, source: sourceCode, target: targetCode,
            completion: { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard seq == self.translationSeq else { return }
                    self.currentTask = nil
                    if let result = result {
                        self.targetTextView.string = result
                        self.overlay.hide()
                        self.targetTextView.scrollToEndOfDocument(nil)
                    } else if let error = error {
                        if (error as NSError).code == NSURLErrorCancelled { return }
                        self.overlay.showError(error.localizedDescription)
                    }
                }
            }
        )
    }

    func showTranslationResult(_ result: String) {
        targetTextView.string = result
        overlay.hide()
    }

    func showTranslationError(_ message: String) {
        overlay.showError(message)
    }

    /// 重置面板状态
    private func resetState() {
        sourceTextView.string = ""
        targetTextView.string = ""
        overlay.hide()
        resetLanguageSelection()
    }

    public func show(with text: String? = nil) {
        resetState()

        let pendingText: String
        if let text = text, !text.isEmpty {
            sourceTextView.string = text
            pendingText = text
        } else {
            pendingText = ""
        }

        // 定位：记忆位置优先，否则鼠标位置
        if let saved = UserDefaults.standard.string(forKey: "translation_panel_origin") {
            let savedPoint = NSPointFromString(saved)
            if !NSEqualPoints(savedPoint, .zero) {
                window?.setFrameOrigin(savedPoint)
            } else {
                fallbackPosition()
            }
        } else {
            fallbackPosition()
        }
        // 记录当前前台 app，粘贴时恢复到它
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if !pendingText.isEmpty {
            // 延迟设焦点 + 滚动到底部
            let pos = pendingText.utf16.count
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.window?.makeKey()
                self.window?.makeFirstResponder(self.sourceTextView)
                self.sourceTextView.setSelectedRange(NSRange(location: pos, length: 0))
                self.sourceTextView.scrollToEndOfDocument(nil)
            }
        }
    }

    public override func close() {
        cancelTranslation()
        window?.orderOut(nil)
        if !AppDelegate.isShowingClipboard {
            NSApplication.shared.hide(nil)
        }
    }

    /// 取消当前翻译任务
    func cancelTranslation() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// NSScrollView 扩展：滚动到底部
    private func scrollToBottom(_ scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        let maxY = max(docView.bounds.height - scrollView.contentSize.height, 0)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// 空面板弹出（不激活，保留源 app 前台便于后续获取选中文本）
    func showEmpty() {
        resetState()
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        // 定位
        if let saved = UserDefaults.standard.string(forKey: "translation_panel_origin") {
            let savedPoint = NSPointFromString(saved)
            if !NSEqualPoints(savedPoint, .zero) {
                window?.setFrameOrigin(savedPoint)
            } else {
                fallbackPosition()
            }
        } else {
            fallbackPosition()
        }
        window?.orderFront(nil)
    }

    /// 激活面板接收键盘输入
    func activateForInput() {
        window?.makeKey()
        window?.makeFirstResponder(sourceTextView)
        window?.orderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// AX 快速获取选中文本（不触发剪贴板兜底）
    func tryAXSelectedText() -> String? {
        guard let app = previousFrontmostApp else { return nil }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let focused = value else { return nil }
        let el = focused as! AXUIElement
        var selectedText: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
              let text = selectedText as? String, !text.isEmpty else { return nil }
        return text
    }

    /// AX → 剪贴板兜底（全路径，面板已显示时用）
    func getSelectedText() -> String? {
        if let text = tryAXSelectedText() { return text }
        return clipboardFallbackSelectedText()
    }

    /// 通过模拟 cmd+c 从粘贴板获取选中文本（不阻塞主线程）
    func clipboardFallbackSelectedText() -> String? {
        let pb = NSPasteboard.general

        // 保存当前粘贴板内容
        let savedItems = pb.pasteboardItems?.flatMap { item -> [(String, Data)] in
            item.types.compactMap { type -> (String, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type.rawValue, data)
            }
        } ?? []

        // 清空粘贴板，准备接收 cmd+c 写入
        pb.clearContents()
        let postClearCount = pb.changeCount

        // 模拟 cmd+c
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            restoreClipboard(savedItems); return nil
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            restoreClipboard(savedItems); return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // 轮询等待 cmd+c 写入（最多 ~120ms，用 run loop 不阻塞主线程）
        var result: String?
        for _ in 0..<6 {
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
            if pb.changeCount > postClearCount {
                result = pb.string(forType: .string)
                break
            }
        }

        // 恢复原始粘贴板内容（无论是否获取到）
        restoreClipboard(savedItems)

        return result
    }

    /// 恢复粘贴板到指定内容
    private func restoreClipboard(_ items: [(String, Data)]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        for (typeRaw, data) in items {
            pb.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
        }
    }
}

// MARK: - Target Overlay View

extension TranslationPanelController {
    enum OverlayMode {
        case loading
        case error
    }

    /// 下面板遮罩：半透明背景 + 居中内容
    final class TargetOverlayView: NSView {
        private let spinner = NSProgressIndicator()
        private let messageLabel = NSTextField(labelWithString: "")

        private(set) var mode: OverlayMode = .loading
        var isVisible: Bool { !isHidden }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) { nil }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = CGColor(red: 0xF5/0xFF, green: 0xF5/0xFF, blue: 0xF5/0xFF, alpha: 0.72)
            layer?.cornerRadius = 4

            spinner.style = .spinning
            spinner.controlSize = .regular
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.isDisplayedWhenStopped = false

            messageLabel.font = NSFont.systemFont(ofSize: 14)
            messageLabel.textColor = NSColor.systemRed
            messageLabel.alignment = .center
            messageLabel.lineBreakMode = .byWordWrapping
            messageLabel.translatesAutoresizingMaskIntoConstraints = false

            // 用垂直 stack 包裹 spinner + label，整体居中
            let stack = NSStackView(views: [spinner, messageLabel])
            stack.orientation = .vertical
            stack.spacing = 16
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            ])
        }

        func showLoading() {
            mode = .loading
            messageLabel.stringValue = ""
            messageLabel.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            isHidden = false
        }

        func showError(_ message: String) {
            mode = .error
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            messageLabel.stringValue = message
            messageLabel.isHidden = false
            isHidden = false
        }

        func hide() {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.stringValue = ""
            isHidden = true
        }
    }
}
