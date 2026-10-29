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

        /// Paste at the visible area when the caret is off-screen, then keep
        /// the scroll position: pasting at an off-screen caret jumps far away.
        override func paste(_ sender: Any?) {
            moveCaretIntoViewIfNeeded()
            let origin = visibleRect.origin
            super.paste(sender)
            scroll(origin)
            if let scrollView = enclosingScrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func moveCaretIntoViewIfNeeded() {
            guard let layout = layoutManager, let container = textContainer else { return }
            let caret = selectedRange()
            let glyphs = layout.glyphRange(forCharacterRange: caret, actualCharacterRange: nil)
            var caretRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let inset = textContainerOrigin
            caretRect.origin.x += inset.x
            caretRect.origin.y += inset.y
            let visible = visibleRect
            guard !visible.intersects(caretRect) else { return }
            let point = NSPoint(x: visible.minX + 2, y: visible.minY + 2)
            let containerPoint = NSPoint(x: point.x - inset.x, y: point.y - inset.y)
            let glyph = layout.glyphIndex(for: containerPoint, in: container)
            let index = layout.characterIndexForGlyph(at: glyph)
            if index != NSNotFound {
                setSelectedRange(NSRange(location: index, length: 0))
            }
        }
    }

    private static let editorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private let textView = EditorTextView(frame: .zero)
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var highlightWork: DispatchWorkItem?
    private var scrollHighlightWork: DispatchWorkItem?
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
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = VSTheme.windowBackground
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 360)

        super.init(window: panel)
        MainActor.assumeIsolated {
            AppWindowRegistry.register(panel)
        }
        setupUI()
        refreshTitles()
        textView.onCommandEnter = { [weak self] in self?.commit() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWindowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: panel,
        )
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

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = VSTheme.windowBackground

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
        textView.backgroundColor = VSTheme.windowBackground
        textView.textColor = VSTheme.editorText
        textView.insertionPointColor = VSTheme.terminalCaret
        textView.selectedTextAttributes = [.backgroundColor: VSTheme.terminalSelection]
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
        // Highlighting only covers visible lines, so scrolling must refresh it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScrollChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView,
        )

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = VSTheme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = VSTheme.secondaryText
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        let footer = NSStackView(views: [statusLabel, hintLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        footer.wantsLayer = true
        footer.layer?.backgroundColor = VSTheme.sidebarBackground.cgColor
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

    @objc private func onWindowBecameKey() {
        window?.makeFirstResponder(textView)
    }

    // MARK: - Load / Save

    private func loadFromDisk() {
        let text = (try? String(contentsOf: AppPaths.configFile, encoding: .utf8)) ?? ""
        textView.string = text
        lastLoadedText = text
        // `string` leaves the caret at EOF; align it with the visible top.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
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
        let source = storage.string as NSString
        let range = visibleLineRange(in: source)
        guard range.length > 0 else { return }
        let slice = source.substring(with: range)
        let base: [NSAttributedString.Key: Any] = [
            .font: Self.editorFont,
            .foregroundColor: VSTheme.editorText,
        ]
        // Keep attribute edits off the undo stack.
        let undo = textView.undoManager
        let suspendUndo = !(undo?.isUndoing ?? false) && !(undo?.isRedoing ?? false)
        if suspendUndo { undo?.disableUndoRegistration() }
        storage.beginEditing()
        // `setAttributes` drops paragraph styles and other model attributes,
        // which leaves runs laid out against stale metrics; set only colors.
        storage.addAttribute(.font, value: Self.editorFont, range: range)
        storage.addAttribute(.foregroundColor, value: VSTheme.editorText, range: range)
        for token in YAMLSyntax.tokens(in: slice) {
            let tokenRange = NSRange(
                location: token.range.location + range.location, length: token.range.length,
            )
            storage.addAttribute(
                .foregroundColor, value: color(for: token.kind), range: tokenRange,
            )
        }
        storage.endEditing()
        invalidateVisibleLayout()
        if suspendUndo { undo?.enableUndoRegistration() }
        textView.typingAttributes = base
    }

    /// Highlighting the whole file on every keystroke is what made typing
    /// stall; only the lines on screen are tokenized.
    private func visibleLineRange(in source: NSString) -> NSRange {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return NSRange(location: 0, length: source.length)
        }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0 else { return NSRange(location: 0, length: 0) }
        return source.lineRange(for: chars)
    }

    @objc private func onScrollChanged() {
        scrollHighlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyHighlight() }
        scrollHighlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Attribute edits can leave the visible runs unrendered until the next
    /// scroll; refresh layout and display for what is on screen only, since a
    /// full re-layout on every keystroke is what makes typing stutter.
    private func invalidateVisibleLayout() {
        let visible = textView.visibleRect
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            textView.needsDisplay = true
            return
        }
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        layout.invalidateLayout(forCharacterRange: chars, actualCharacterRange: nil)
        layout.invalidateDisplay(forCharacterRange: chars)
        textView.setNeedsDisplay(visible)
    }

    private func color(for kind: YAMLTokenKind) -> NSColor {
        switch kind {
        case .comment: VSTheme.syntaxComment
        case .key: VSTheme.syntaxKey
        case .string: VSTheme.syntaxString
        case .scalar: VSTheme.syntaxNumber
        case .punctuation: VSTheme.syntaxPunctuation
        }
    }

    private func commit() {
        let text = textView.string
        do {
            try ConfigManager.shared.apply(rawText: text)
            lastLoadedText = text
            setStatus(L10n.Config.editorSaved, color: VSTheme.success)
            onApplied()
        } catch {
            debugLog("[ConfigEditor] validation failed: \(error)")
            setStatus(L10n.Config.editorInvalid(message: error.localizedDescription), color: VSTheme.error)
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
