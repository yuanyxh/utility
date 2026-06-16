import Cocoa

/// 翻译面板 — 26 语种支持
/// 上方原文 + 左侧语言选择，下方译文 + 右侧语言选择
/// enter 翻译，cmd+enter 换行，esc 关闭，ctrl+enter 粘贴译文
/// 自定义面板 — 用 performKeyEquivalent 处理快捷键
private final class TranslationPanel: NSPanel {
    weak var controller: TranslationPanelController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53: // esc
            controller?.close()
            return true
        case 36: // return / enter
            if !flags.contains(.command) {
                controller?.performTranslation()
                return true
            }
            // cmd+enter = 默认换行
        case 46: // m / M
            if flags == .control {
                controller?.pasteTranslation()
                controller?.close()
                return true
            }
        default:
            break
        }
        // 标准 cmd+编辑快捷键（cmd+c/x/v/a/z 等）交给 NSTextView 的 keyDown:
        return false
    }
}

/// 自定义 NSTextView：Enter 触发翻译，阻止换行
private final class TranslationTextView: NSTextView {
    weak var controller: TranslationPanelController?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36, !flags.contains(.command) {
            // 纯 Enter → 翻译
            controller?.performTranslation()
            return
        }
        // cmd+enter → 换行；其他键正常处理
        super.keyDown(with: event)
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
    private var currentTask: URLSessionTask?
    /// 翻译序列号（用于判断任务是否已过期）
    private var translationSeq: UInt = 0

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

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) else { return }
        keyDown.flags = .maskCommand
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
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
        sourceTextView.becomeFirstResponder()
        sourceTextView.setSelectedRange(NSRange(location: 0, length: 0))
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
        NSApplication.shared.hide(nil)
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

    /// 获取当前选中文本（优先 Accessibility API，失败时回退到模拟复制）
    func getSelectedText() -> String? {
        // 方法一：Accessibility API（需辅助功能权限）
        if let text = Self._getSelectedTextAccessibility() {
            return text
        }

        // 方法二：模拟 cmd+c → 读粘贴板 → 恢复
        return Self._getSelectedTextPasteboard()
    }

    /// Accessibility API 方式
    private static func _getSelectedTextAccessibility() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appPID = app.processIdentifier

        let appRef = AXUIElementCreateApplication(appPID)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef,
                                                    kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let focused = value else { return nil }

        let focusedElement = focused as! AXUIElement
        var selectedText: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            focusedElement, kAXSelectedTextAttribute as CFString, &selectedText)

        if textResult == .success, let text = selectedText as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    /// 模拟复制方式（通用，无需权限）
    private static func _getSelectedTextPasteboard() -> String? {
        let pb = NSPasteboard.general
        let savedChangeCount = pb.changeCount

        // 保存当前粘贴板内容
        let savedData = pb.data(forType: .string)

        // 模拟 cmd+c
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true) else { return nil }
        keyDown.flags = .maskCommand
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return nil }
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // 等粘贴板更新
        usleep(100_000) // 100ms

        // 读取粘贴板
        let copiedText = pb.string(forType: .string)

        // 恢复原内容（如果有且改变了才恢复）
        if pb.changeCount != savedChangeCount {
            pb.clearContents()
            if let saved = savedData {
                pb.setData(saved, forType: .string)
            }
        }

        return copiedText
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
