import Cocoa

/// Config editor; ⌘↩ validates before writing, then reloads.
final class ConfigEditorWindowController: NSWindowController, NSTextViewDelegate {
    private final class EditorTextView: NSTextView {
        var onCommandEnter: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
                onCommandEnter?()
                return
            }
            super.keyDown(with: event)
        }
    }

    private static let editorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private let textView = EditorTextView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var highlightWork: DispatchWorkItem?
    /// Last loaded/saved text; keeps unsaved edits on re-show.
    private var lastLoadedText = ""
    private let onApplied: () -> Void

    init(onApplied: @escaping () -> Void) {
        self.onApplied = onApplied
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false,
        )
        panel.title = L10n.Config.editorTitle
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 360)

        super.init(window: panel)
        setupUI()
        refreshTitles()
        textView.onCommandEnter = { [weak self] in self?.commit() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
        if !panel.setFrameAutosaveName("utility.config-editor") {
            panel.center()
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Public

    func show() {
        if textView.string == lastLoadedText {
            loadFromDisk()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(textView)
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        textView.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude,
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude,
        )
        textView.font = Self.editorFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.delegate = self
        scrollView.documentView = textView

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        let footer = NSStackView(views: [statusLabel, hintLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [scrollView, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func refreshTitles() {
        window?.title = L10n.Config.editorTitle
        hintLabel.stringValue = L10n.Config.editorHint
    }

    @objc private func onLanguageChanged() {
        refreshTitles()
    }

    // MARK: - Load / Save

    private func loadFromDisk() {
        let text = (try? String(contentsOf: AppPaths.configFile, encoding: .utf8)) ?? ""
        textView.string = text
        lastLoadedText = text
        applyHighlight()
    }

    // MARK: - Syntax highlighting

    func textDidChange(_: Notification) {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyHighlight() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func applyHighlight() {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let text = storage.string
        let base: [NSAttributedString.Key: Any] = [
            .font: Self.editorFont,
            .foregroundColor: NSColor.labelColor,
        ]
        // Keep attribute edits off the undo stack.
        let undo = textView.undoManager
        let suspendUndo = !(undo?.isUndoing ?? false) && !(undo?.isRedoing ?? false)
        if suspendUndo { undo?.disableUndoRegistration() }
        storage.beginEditing()
        storage.setAttributes(
            base, range: NSRange(location: 0, length: (text as NSString).length),
        )
        for token in YAMLSyntax.tokens(in: text) {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        storage.endEditing()
        if suspendUndo { undo?.enableUndoRegistration() }
        textView.typingAttributes = base
    }

    private func color(for kind: YAMLTokenKind) -> NSColor {
        switch kind {
        case .comment: .secondaryLabelColor
        case .key: .systemBlue
        case .string: .systemRed
        case .scalar: .systemPurple
        case .punctuation: .systemTeal
        }
    }

    private func commit() {
        let text = textView.string
        do {
            try ConfigManager.shared.apply(rawText: text)
            lastLoadedText = text
            setStatus(L10n.Config.editorSaved, color: .secondaryLabelColor)
            onApplied()
        } catch {
            debugLog("[ConfigEditor] validation failed: \(error)")
            setStatus(L10n.Config.editorInvalid(message: error.localizedDescription), color: .systemRed)
            presentValidationAlert(error)
        }
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.toolTip = text
    }

    private func presentValidationAlert(_ error: Error) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Config.editorInvalidTitle
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.Config.editorOk)
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.window?.makeFirstResponder(self?.textView)
        }
    }
}
