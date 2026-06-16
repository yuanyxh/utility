import Cocoa

/// 翻译面板 — 26 语种支持
/// 上方原文 + 左语言选择，下方译文 + 右语言选择
/// enter 翻译，cmd+enter 换行，esc 关闭，ctrl+enter 粘贴译文
public final class TranslationPanelController: NSWindowController {
    private let sourceTextView = NSTextView()
    private let targetTextView = NSTextView()
    private let sourceLangPopup = NSPopUpButton()
    private let targetLangPopup = NSPopUpButton()
    private let loadingIndicator = NSProgressIndicator()
    private let scrollViewSource = NSScrollView()
    private let scrollViewTarget = NSScrollView()

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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                             styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.level = NSWindow.Level.floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        setupUI()
    }

    required init?(coder: NSCoder) { nil }

    private func setupUI() {
        guard let panel = window else { return }

        // ---- 原文区 ----
        let sourceLabel = NSTextField(labelWithString: "原文")
        sourceLabel.font = NSFont.boldSystemFont(ofSize: 12)

        sourceLangPopup.target = self
        setupLanguagePopups()

        let sourceTopRow = NSStackView(views: [sourceLabel, sourceLangPopup])
        sourceTopRow.orientation = .horizontal
        sourceTopRow.alignment = .firstBaseline

        sourceTextView.isEditable = true
        sourceTextView.isRichText = false
        sourceTextView.font = NSFont.systemFont(ofSize: 13)
        sourceTextView.wantsLayer = true
        sourceTextView.layer?.borderWidth = 0.5
        sourceTextView.layer?.borderColor = NSColor.separatorColor.cgColor
        sourceTextView.layer?.cornerRadius = 4

        scrollViewSource.documentView = sourceTextView
        scrollViewSource.hasVerticalScroller = true
        scrollViewSource.borderType = .noBorder

        let sourceSection = NSStackView(views: [sourceTopRow, scrollViewSource])
        sourceSection.orientation = .vertical
        sourceSection.spacing = 4

        // ---- 译文区 ----
        let targetLabel = NSTextField(labelWithString: "译文")
        targetLabel.font = NSFont.boldSystemFont(ofSize: 12)

        targetLangPopup.target = self

        let targetTopRow = NSStackView(views: [targetLabel, targetLangPopup])
        targetTopRow.orientation = .horizontal
        targetTopRow.alignment = .firstBaseline

        targetTextView.isEditable = false
        targetTextView.isRichText = false
        targetTextView.font = NSFont.systemFont(ofSize: 13)
        targetTextView.wantsLayer = true
        targetTextView.layer?.borderWidth = 0.5
        targetTextView.layer?.borderColor = NSColor.separatorColor.cgColor
        targetTextView.layer?.cornerRadius = 4

        scrollViewTarget.documentView = targetTextView
        scrollViewTarget.hasVerticalScroller = true
        scrollViewTarget.borderType = .noBorder

        let targetSection = NSStackView(views: [targetTopRow, scrollViewTarget])
        targetSection.orientation = .vertical
        targetSection.spacing = 4

        // ---- 加载指示 ----
        loadingIndicator.style = .spinning
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.controlSize = .small

        // ---- 分隔线 + 布局 ----
        let divider = NSBox()
        divider.boxType = .separator

        let mainStack = NSStackView(views: [sourceSection, divider, targetSection])
        mainStack.orientation = .vertical
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        // 等分高度
        scrollViewSource.heightAnchor.constraint(equalTo: scrollViewTarget.heightAnchor).isActive = true
        panel.contentView = mainStack

        // 加载指示器覆盖
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(loadingIndicator)
        loadingIndicator.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor).isActive = true
        loadingIndicator.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor).isActive = true

        // 键盘监听
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
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
        let targetCode = ConfigManager.shared.config.translation.targetLang
        if let idx = languages.firstIndex(where: { $0.code == targetCode }) {
            targetLangPopup.selectItem(at: idx)
        }
    }

    // MARK: - Key Events

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // esc — 关闭
            close()
            return nil
        case 36: // return
            if !event.modifierFlags.contains(.command) {
                // enter → 触发翻译
                performTranslation()
                return nil
            }
            // cmd+enter → 换行（默认行为）
        case 46: // cmd+enter (M)
            if event.modifierFlags.contains(.command) &&
                event.modifierFlags.contains(.shift) {
                // ctrl+enter — 粘贴译文到原焦点
                pasteTranslation()
                close()
                return nil
            }
        default:
            break
        }
        return event
    }

    // MARK: - Translation

    private func performTranslation() {
        let text = sourceTextView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let sourceCode = sourceLangPopup.selectedItem?.representedObject as? String ?? "auto"
        let targetCode = targetLangPopup.selectedItem?.representedObject as? String ?? "zh"

        loadingIndicator.startAnimation(nil)
        targetTextView.string = "翻译中…"

        Task {
            do {
                let result = try await Translator.shared.translate(
                    text: text, source: sourceCode, target: targetCode
                )
                await MainActor.run {
                    self.targetTextView.string = result
                    self.loadingIndicator.stopAnimation(nil)
                }
            } catch {
                await MainActor.run {
                    self.targetTextView.string = "翻译失败: \(error.localizedDescription)"
                    self.loadingIndicator.stopAnimation(nil)
                }
            }
        }
    }

    // MARK: - Paste Translation

    private func pasteTranslation() {
        let text = targetTextView.string
        guard !text.isEmpty, text != "翻译中…", !text.hasPrefix("翻译失败") else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 模拟 cmd+v
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) else { return }
        keyDown.flags = .maskCommand
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Show / Close

    /// 显示翻译面板
    /// - Parameter text: 初始填入的文本（选中文本自动传入）
    public func show(with text: String? = nil) {
        if let text = text, !text.isEmpty {
            sourceTextView.string = text
        } else {
            sourceTextView.string = ""
        }
        targetTextView.string = ""
        resetLanguageSelection()

        let mouse = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero
        frame.origin.x = mouse.x - 260
        frame.origin.y = mouse.y - frame.height + 30
        window?.setFrame(frame, display: true)

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        sourceTextView.becomeFirstResponder()
    }

    public override func close() {
        window?.orderOut(nil)
        // 还原焦点
        NSApplication.shared.hide(nil)
    }

    /// 获取当前活跃 app 的选中文本（通过 Accessibility API）
    public static func getSelectedText() -> String? {
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
}
