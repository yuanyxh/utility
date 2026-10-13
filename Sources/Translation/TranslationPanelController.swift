import Cocoa

/// Custom NSPanel: intercept cmd+c/x/v/a/z editing shortcuts and hand them to the first responder
private final class TranslationPanel: NSPanel {
    weak var controller: TranslationPanelController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.keyCode {
            case 8: // c
                if let textView = firstResponder as? NSTextView {
                    textView.copy(nil)
                    return true
                }
            case 7: // x
                if let textView = firstResponder as? NSTextView, textView.isEditable {
                    textView.cut(nil)
                    return true
                }
            case 9: // v
                if let textView = firstResponder as? NSTextView, textView.isEditable {
                    textView.paste(nil)
                    return true
                }
            case 0: // a
                if let textView = firstResponder as? NSTextView {
                    textView.selectAll(nil)
                    return true
                }
            case 6: // z — left to keyDown to handle
                break
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

public final class TranslationPanelController: NSWindowController {
    private let sourceInputView: ScrolledInputTextView = {
        let style = InputViewStyle(
            font: .systemFont(ofSize: 13),
            textContainerInset: NSSize(width: 6, height: 6),
            showsVerticalScroller: true,
            border: BorderStyle(color: .separatorColor, width: 0.5, cornerRadius: 4),
        )
        let v = ScrolledInputTextView(style: style)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let sourceLangPopup = NSPopUpButton()
    private let targetLangPopup = NSPopUpButton()
    private let sourceLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")

    private let targetOutput = ScrolledInputTextView(style: InputViewStyle(
        font: .systemFont(ofSize: 13),
        textContainerInset: NSSize(width: 6, height: 6),
        isEditable: false,
        showsVerticalScroller: true,
        border: BorderStyle(color: .separatorColor, width: 0.5, cornerRadius: 4),
    ))

    /// Overlay for the lower panel
    private let overlay = OverlayView()

    /// Current translation task (used for cancellation)
    var currentTask: URLSessionTask?
    /// Whether a translation is running
    var isTranslating: Bool {
        currentTask != nil
    }

    /// Translation sequence number (used to tell whether a task is stale)
    private var translationSeq: UInt = 0

    /// Frontmost app before the panel opened (restored when pasting)
    var previousFrontmostApp: NSRunningApplication?

    /// 27 languages (sorted by usage), names shown in each language's native script
    private let languages: [(code: String, name: String)] = [
        ("auto", "Auto"),
        ("zh", "中文"),
        ("en", "English"),
        ("es", "Español"),
        ("hi", "हिन्दी"),
        ("ar", "العربية"),
        ("bn", "বাংলা"),
        ("pt", "Português"),
        ("ru", "Русский"),
        ("ja", "日本語"),
        ("pa", "ਪੰਜਾਬੀ"),
        ("de", "Deutsch"),
        ("jv", "Basa Jawa"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("te", "తెలుగు"),
        ("mr", "मराठी"),
        ("ta", "தமிழ்"),
        ("ur", "اردو"),
        ("vi", "Tiếng Việt"),
        ("it", "Italiano"),
        ("th", "ไทย"),
        ("ms", "Bahasa Melayu"),
        ("tr", "Türkçe"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
        ("uk", "Українська"),
    ]

    public init() {
        let panel = TranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false,
        )
        panel.level = NSWindow.Level.floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.controller = self
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
    }

    required init?(coder _: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        guard let panel = window else { return }
        let content = panel.contentView!

        // ---- Source area ----
        let sourceLabel = sourceLabel
        sourceLabel.stringValue = L10n.Translation.source
        sourceLabel.font = NSFont.boldSystemFont(ofSize: 12)

        sourceLangPopup.target = self
        sourceLangPopup.action = #selector(sourceLangChanged)
        setupLanguagePopups()

        let sourceSpacer = NSView()
        sourceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sourceTopRow = NSStackView(views: [sourceLabel, sourceSpacer, sourceLangPopup])
        sourceTopRow.orientation = .horizontal
        sourceTopRow.alignment = .firstBaseline

        let sourceSection = NSStackView(views: [sourceTopRow, sourceInputView])
        sourceSection.orientation = .vertical
        sourceSection.spacing = 4
        sourceSection.translatesAutoresizingMaskIntoConstraints = false

        // ---- Target area ----
        let targetLabel = targetLabel
        targetLabel.stringValue = L10n.Translation.target
        targetLabel.font = NSFont.boldSystemFont(ofSize: 12)

        targetLangPopup.target = self
        targetLangPopup.action = #selector(targetLangChanged)

        let targetSpacer = NSView()
        targetSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let targetTopRow = NSStackView(views: [targetLabel, targetSpacer, targetLangPopup])
        targetTopRow.orientation = .horizontal
        targetTopRow.alignment = .firstBaseline

        targetOutput.translatesAutoresizingMaskIntoConstraints = false

        let targetSection = NSStackView(views: [targetTopRow, targetOutput])
        targetSection.orientation = .vertical
        targetSection.spacing = 4
        targetSection.translatesAutoresizingMaskIntoConstraints = false

        // ---- Overlay ----
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true

        // ---- Layout ----
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

            sourceInputView.heightAnchor.constraint(equalTo: targetOutput.heightAnchor),

            // The overlay covers the lower panel area (inset 1pt so it doesn't cover the border)
            overlay.topAnchor.constraint(equalTo: targetOutput.topAnchor, constant: 1),
            overlay.leadingAnchor.constraint(equalTo: targetOutput.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: targetOutput.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: targetOutput.bottomAnchor, constant: -1),
        ])

        // Remember position when dragging stops
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition),
            name: NSWindow.didMoveNotification, object: panel,
        )
    }

    @objc private func savePosition() {
        guard let origin = window?.frame.origin else { return }
        WindowPositioning.savePosition(origin, forKey: UDKey.translationPanelOrigin)
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

    @objc private func sourceLangChanged(_: Any) {
        guard !sourceInputView.string.isEmpty else { return }
        startTranslation(text: sourceInputView.string)
    }

    @objc private func targetLangChanged(_: Any) {
        guard !sourceInputView.string.isEmpty else { return }
        startTranslation(text: sourceInputView.string)
    }

    // MARK: - Translation

    fileprivate func performTranslation() {
        let text = sourceInputView.string
        startTranslation(text: text)
    }

    // MARK: - Paste Translation

    fileprivate func pasteTranslation() {
        let text = targetOutput.string
        guard !text.isEmpty else { return }
        guard !overlay.isVisible || overlay.mode == .error else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        EventBus.shared.publish(PanelEvent.requestPaste, payload: self)
    }

    // MARK: - Show / Close

    /// Whether the panel is currently visible
    var isPanelVisible: Bool {
        window?.isVisible ?? false
    }

    /// When the panel is already shown: fill in the selected text and trigger translation (does not move the panel)
    func fillAndTranslate(_ text: String) {
        guard !text.isEmpty else { return }
        sourceInputView.string = text
        targetOutput.clear()
        overlay.hide()
        resetLanguageSelection()
        sourceInputView.scroll(to: .bottom)
        startTranslation(text: text)
    }

    /// Trigger translation via callback
    func startTranslation(text: String) {
        // Cancel the old task; the sequence number prevents old callbacks from interfering
        currentTask?.cancel()
        currentTask = nil
        let seq = translationSeq + 1
        translationSeq = seq

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let config = ConfigManager.shared.config
        guard !config.ai.apiKey.isEmpty else {
            overlay.showError(L10n.Translation.noApiKey)
            return
        }

        targetOutput.clear()
        overlay.showLoading()
        let sourceCode = sourceLangPopup.selectedItem?.representedObject as? String ?? "auto"
        let targetCode = targetLangPopup.selectedItem?.representedObject as? String ?? "zh"
        currentTask = Translator.shared.translate(
            text: text, source: sourceCode, target: targetCode,
            completion: { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard seq == self.translationSeq else { return }
                    self.currentTask = nil
                    if let result {
                        self.targetOutput.string = result
                        self.overlay.hide()
                        self.targetOutput.scroll(to: .bottom)
                    } else if let error {
                        if (error as NSError).code == NSURLErrorCancelled { return }
                        self.overlay.showError(error.localizedDescription)
                    }
                }
            },
        )
    }

    /// Reset panel state
    private func resetState() {
        sourceInputView.string = ""
        targetOutput.clear()
        overlay.hide()
        resetLanguageSelection()
    }

    public func show(with text: String? = nil) {
        resetState()

        let pendingText: String
        if let text, !text.isEmpty {
            sourceInputView.string = text
            pendingText = text
        } else {
            pendingText = ""
        }

        // Positioning: remember position first, otherwise mouse position
        let origin = WindowPositioning.savedOrNearMouse(
            windowSize: window?.frame.size ?? .zero,
            key: UDKey.translationPanelOrigin,
            screen: window?.screen,
        )
        window?.setFrameOrigin(origin)
        // Record the current frontmost app, restore to it when pasting
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if !pendingText.isEmpty {
            // Delay setting focus + scroll to bottom
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self else { return }
                window?.makeKey()
                window?.makeFirstResponder(sourceInputView.textView)
                sourceInputView.setCursor(to: .end)
                sourceInputView.scroll(to: .bottom)
            }
        }
    }

    override public func close() {
        cancelTranslation()
        sourceInputView.clear()
        EventBus.shared.publish(PanelEvent.requestClose, payload: self)
    }

    /// Cancel the current translation task
    func cancelTranslation() {
        currentTask?.cancel()
        currentTask = nil
    }

    func refreshTitles() {
        sourceLabel.stringValue = L10n.Translation.source
        targetLabel.stringValue = L10n.Translation.target
    }

    @objc private func onLanguageChanged() {
        refreshTitles()
    }

    /// Pop up an empty panel (not activated, keeps the source app frontmost so selected text can be fetched later)
    func showEmpty() {
        resetState()
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        // Positioning
        let origin = WindowPositioning.savedOrNearMouse(
            windowSize: window?.frame.size ?? .zero,
            key: UDKey.translationPanelOrigin,
            screen: window?.screen,
        )
        window?.setFrameOrigin(origin)
        window?.orderFront(nil)
    }

    /// Activate the panel to receive keyboard input
    func activateForInput() {
        window?.makeKey()
        window?.makeFirstResponder(sourceInputView.textView)
        window?.orderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// MARK: - PanelProtocol

extension TranslationPanelController: PanelProtocol {
    var panelID: String {
        "translation"
    }

    var panelWindow: NSWindow? {
        window
    }

    func showPanel(context: [String: Any]?) {
        if let text = context?["text"] as? String, !text.isEmpty {
            show(with: text)
            startTranslation(text: text)
            return
        }

        if isPanelVisible {
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard let app = previousFrontmostApp else { return }
            Task { @MainActor in
                if let text = await SelectedTextService.getSelectedText(from: app) {
                    fillAndTranslate(text)
                }
            }
            return
        }

        let preApp = NSWorkspace.shared.frontmostApplication
        previousFrontmostApp = preApp

        showEmpty()
        guard let app = preApp else { return }
        Task { @MainActor in
            if let text = await SelectedTextService.getSelectedText(from: app), !text.isEmpty {
                activateForInput()
                fillAndTranslate(text)
            } else {
                activateForInput()
            }
        }
    }

    func closePanel() {
        cancelTranslation()
        sourceInputView.clear()
        window?.orderOut(nil)
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            EventBus.shared.publish(PanelEvent.requestClose, payload: self)
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 {
            if flags == .command {
                performTranslation()
                return true
            }
            if flags == .shift {
                sourceInputView.insertNewline()
                return true
            }
            if !flags.contains(.command), !flags.contains(.control) {
                if isTranslating { return true }
                pasteTranslation()
                return true
            }
            return false
        }
        if event.keyCode == 6 { // z
            if flags.contains(.command), !flags.contains(.shift) {
                sourceInputView.undo()
                return true
            }
            return false
        }
        return false
    }
}
