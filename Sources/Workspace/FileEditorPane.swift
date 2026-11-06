import Cocoa

/// Owns its undo stack so highlight attribute edits and window-level operations
/// cannot leave the editor without an undoable step.
private final class EditorTextView: NSTextView {
    private let editorUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        editorUndoManager
    }
}

/// Text editor with a line-number gutter, draft snapshots and external-change handling.
@MainActor
final class FileEditorPane: NSView, WorkspacePanel, NSTextViewDelegate {
    let panelID = PanelID.editor
    var focusTarget: NSView? { textView }

    var onDidSave: (() -> Void)?
    var onDirtyChange: ((Bool) -> Void)?
    var onExternalChange: ((ExternalChange) -> Void)?
    var onPreviewModeChange: ((EditorPreviewMode) -> Void)?
    var onPositionChange: ((Int, Double) -> Void)?

    private(set) var document: FileDocument?
    private(set) var rootURL: URL?

    private let headerLabel = NSTextField(labelWithString: "")
    private let scrollView = OverlayScrollView()
    private let textView = EditorTextView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let markdownPreview: MarkdownPreviewView = {
        let view = MarkdownPreviewView()
        view.wantsLayer = true
        view.layer?.backgroundColor = VSTheme.editorBackground.cgColor
        return view
    }()
    private let imagePreview = ImagePreviewView()
    private let sourceButton = PointerButton()
    private let previewButton = PointerButton()
    private var previewMode: EditorPreviewMode = .source
    private var markdownURL: URL?
    private let banner = NSView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private var bannerButtons: [NSButton] = []
    private var bannerDeleted = false
    private var ruler: LineNumberRulerView?
    private var pendingURL: URL?
    private var pendingFocus = true
    private var pendingPosition: (caret: Int, scrollY: Double)?
    private var loadGeneration = 0
    private var draftWorkItem: DispatchWorkItem?
    private var dirtyWorkItem: DispatchWorkItem?
    private var positionWorkItem: DispatchWorkItem?
    private var syntaxDefinition: SyntaxDefinition?
    private var highlightWorkItem: DispatchWorkItem?
    private var highlightDisabled = false
    private var lastRendered: EditorUIState?
    private var lastPreviewMode: EditorPreviewMode?
    private let draftStore = EditorDraftStore()
    private let syntaxProvider: any SyntaxProvider

    private(set) var isDirty = false

    override init(frame frameRect: NSRect) {
        self.syntaxProvider = DefaultSyntaxProvider()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.editorBackground.cgColor
        setup()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - WorkspacePanel

    func render(_ snapshot: WorkspaceSnapshot) {
        let state = snapshot.editor
        if state != lastRendered {
            lastRendered = state
            if state.isDirty != isDirty {
                isDirty = state.isDirty
                updateHeader()
            }
            applyExternalChange(state.externalChange)
        }
        if snapshot.ui.previewMode != lastPreviewMode {
            lastPreviewMode = snapshot.ui.previewMode
            applyPreviewMode(snapshot.ui.previewMode)
        }
    }

    private func applyExternalChange(_ change: ExternalChange) {
        switch change {
        case .unchanged: hideBanner()
        case .modified: showBanner(deleted: false)
        case .deleted: showBanner(deleted: true)
        }
    }

    private func applyPreviewMode(_ mode: EditorPreviewMode) {
        guard markdownURL != nil else { return }
        previewMode = mode == .markdown ? .markdown : .source
        if previewMode == .markdown { renderMarkdownPreview() }
        updatePreviewVisibility()
        updateModeButtons()
    }

    private func setDirty(_ value: Bool) {
        guard isDirty != value else { return }
        isDirty = value
        onDirtyChange?(value)
    }

    // MARK: - Public

    func open(
        url: URL, root: URL?, focus: Bool = true, position: (caret: Int, scrollY: Double)? = nil,
    ) {
        if document?.url == url || pendingURL == url { return }
        pendingURL = url
        pendingFocus = focus
        pendingPosition = position
        rootURL = root
        loadGeneration += 1
        let generation = loadGeneration
        headerLabel.stringValue = url.lastPathComponent
        headerLabel.toolTip = url.path
        hideBanner()
        onExternalChange?(.unchanged)

        if ImagePreviewView.supportedExtensions.contains(url.pathExtension.lowercased()) {
            pendingURL = nil
            showImage(url: url, generation: generation)
            return
        }

        let maxBytes = maxFileBytes
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FileDocument.load(url: url, maxBytes: maxBytes)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.pendingURL = nil
                self.apply(result, url: url, maxBytes: maxBytes)
            }
        }
    }

    /// Restores a crash snapshot into the editor without touching the file on disk.
    func restore(_ draft: EditorDraft, root: URL?) {
        loadGeneration += 1
        pendingURL = nil
        rootURL = root
        let document: FileDocument
        if case .text(let loaded) = FileDocument.load(url: draft.fileURL, maxBytes: maxFileBytes) {
            document = loaded
        } else {
            document = FileDocument(
                url: draft.fileURL, text: "", encoding: draft.encoding, hadBOM: false,
                lineEnding: draft.lineEnding, fingerprint: draft.fingerprint,
            )
        }
        document.updateText(draft.text)
        setDirty(true)
        onExternalChange?(.unchanged)
        self.document = document
        textView.string = draft.text
        textView.undoManager?.removeAllActions()
        textView.isEditable = true
        ruler?.rebuildLineStarts(draft.text)
        scrollView.isHidden = false
        emptyLabel.isHidden = true
        updateHeader()
        preparePreview(for: draft.fileURL)
        rebuildHighlightState()
        window?.makeFirstResponder(textView)
    }

    func close() {
        discardDraft()
        highlightWorkItem?.cancel()
        syntaxDefinition = nil
        loadGeneration += 1
        pendingURL = nil
        document = nil
        setDirty(false)
        onExternalChange?(.unchanged)
        textView.string = ""
        hidePreview()
        headerLabel.stringValue = ""
        hideBanner()
        showMessage(L10n.Workspace.editorEmpty)
    }

    /// Returns false only when the user cancels or a save fails.
    func confirmClose() -> Bool {
        guard let document, isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.Workspace.unsavedTitle
        alert.informativeText = L10n.Workspace.unsavedBody(name: document.url.lastPathComponent)
        alert.addButton(withTitle: L10n.Workspace.unsavedSave)
        alert.addButton(withTitle: L10n.Workspace.unsavedDiscard)
        alert.addButton(withTitle: L10n.Workspace.unsavedCancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            discardDraft()
            setDirty(false)
            updateHeader()
            return true
        default:
            return false
        }
    }

    /// Checks the file on disk and reloads or warns depending on local edits.
    func checkExternalChange() {
        guard let document, pendingURL == nil else { return }
        switch document.checkExternalChange() {
        case .unchanged:
            onExternalChange?(.unchanged)
        case .modified:
            if isDirty {
                onExternalChange?(.modified)
            } else {
                reloadFromDisk()
            }
        case .deleted:
            onExternalChange?(.deleted)
        }
    }

    // MARK: - Saving

    @discardableResult
    func save() -> Bool {
        persist(overwriteExternal: false)
    }

    @discardableResult
    func saveAs() -> Bool {
        guard let document else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.lastPathComponent
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.title = L10n.Workspace.saveAsTitle
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let previousURL = document.url
        document.updateText(textView.string)
        do {
            self.document = try document.savedCopy(at: url)
            if previousURL != url { draftStore.delete(for: previousURL) }
            rootURL = rootURL ?? url.deletingLastPathComponent()
            headerLabel.stringValue = url.lastPathComponent
            headerLabel.toolTip = url.path
            finishSave()
            return true
        } catch {
            presentSaveError(error)
            return false
        }
    }

    @objc func saveEditorDocument(_: Any?) {
        save()
    }

    @objc func saveEditorDocumentAs(_: Any?) {
        saveAs()
    }

    private func persist(overwriteExternal: Bool) -> Bool {
        guard let document else { return true }
        document.updateText(textView.string)
        do {
            try document.save(overwriteExternal: overwriteExternal)
            finishSave()
            return true
        } catch FileSaveError.externalModified {
            switch resolveConflict() {
            case .overwrite: return persist(overwriteExternal: true)
            case .reload:
                reloadFromDisk()
                return false
            case .cancel:
                return false
            }
        } catch FileSaveError.missing {
            return saveAs()
        } catch {
            presentSaveError(error)
            return false
        }
    }

    private enum ConflictChoice { case overwrite, reload, cancel }

    private func resolveConflict() -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = L10n.Workspace.conflictTitle
        alert.informativeText = L10n.Workspace.conflictBody
        alert.addButton(withTitle: L10n.Workspace.conflictOverwrite)
        alert.addButton(withTitle: L10n.Workspace.conflictReload)
        alert.addButton(withTitle: L10n.Workspace.conflictCompare)
        alert.addButton(withTitle: L10n.Workspace.unsavedCancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .reload
        case .alertThirdButtonReturn:
            presentComparison()
            return .cancel
        default: return .cancel
        }
    }

    private func finishSave() {
        draftWorkItem?.cancel()
        if let url = document?.url { draftStore.delete(for: url) }
        setDirty(false)
        onExternalChange?(.unchanged)
        updateHeader()
        onDidSave?()
    }

    private func presentSaveError(_ error: Error) {
        let message: String
        switch error {
        case FileSaveError.readOnly: message = L10n.Workspace.saveReadOnly
        case FileSaveError.writeFailed(let detail): message = L10n.Workspace.saveError(detail: detail)
        default: message = L10n.Workspace.saveError(detail: String(describing: error))
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Workspace.saveFailedTitle
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Disk changes

    private func reloadFromDisk() {
        guard let document, case .text(let fresh) = FileDocument.load(url: document.url, maxBytes: maxFileBytes)
        else { return }
        let offset = scrollView.contentView.bounds.origin
        document.applyReload(fresh)
        setDirty(false)
        onExternalChange?(.unchanged)
        textView.string = fresh.text
        textView.undoManager?.removeAllActions()
        ruler?.rebuildLineStarts(fresh.text)
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        hideBanner()
        updateHeader()
        rebuildHighlightState()
        draftStore.delete(for: document.url)
    }

    private func presentComparison() {
        guard let document else { return }
        let diskText: String
        if case .text(let fresh) = FileDocument.load(url: document.url, maxBytes: maxFileBytes) {
            diskText = fresh.text
        } else {
            diskText = ""
        }
        EditorDraftDiffWindow.present(
            title: L10n.Workspace.conflictCompare,
            name: document.url.lastPathComponent,
            diskText: diskText, localText: textView.string,
        )
    }

    // MARK: - Drafts

    private func scheduleDraftSnapshot() {
        draftWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeDraftSnapshot() }
        draftWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func writeDraftSnapshot() {
        guard let document, isDirty else { return }
        document.updateText(textView.string)
        let draft = EditorDraft(
            url: document.url, text: document.text, encoding: document.encoding,
            lineEnding: document.lineEnding, fingerprint: document.fingerprint,
        )
        let store = draftStore
        DispatchQueue.global(qos: .utility).async { try? store.save(draft) }
    }

    private func discardDraft() {
        draftWorkItem?.cancel()
        if let url = document?.url { draftStore.delete(for: url) }
    }

    // MARK: - UI

    private var maxFileBytes: Int {
        max(1, ConfigManager.shared.config.workspace.maxFileSizeMB) * 1024 * 1024
    }

    private func setup() {
        headerLabel.font = .systemFont(ofSize: 11)
        headerLabel.textColor = VSTheme.secondaryText
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude,
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude,
        )
        textView.font = VSTheme.editorFont(size: 12)
        textView.backgroundColor = VSTheme.editorBackground
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
        if let undoManager = textView.undoManager {
            for name in [
                Notification.Name.NSUndoManagerDidUndoChange,
                Notification.Name.NSUndoManagerDidRedoChange,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(onUndoChange), name: name, object: undoManager,
                )
            }
        }
        textView.typingAttributes = [
            .font: VSTheme.editorFont(size: 12),
            .foregroundColor: VSTheme.editorText,
        ]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = VSTheme.editorBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = ruler
        self.ruler = ruler

        NotificationCenter.default.addObserver(
            self, selector: #selector(onScrollChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView,
        )

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = VSTheme.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        setupBanner()

        configureModeButton(
            sourceButton,
            symbol: "chevron.left.forwardslash.chevron.right",
            toolTip: L10n.Workspace.source,
            action: #selector(onShowSource),
        )
        configureModeButton(
            previewButton,
            symbol: "eye",
            toolTip: L10n.Workspace.preview,
            action: #selector(onShowPreview),
        )

        markdownPreview.isHidden = true
        imagePreview.isHidden = true

        addSubview(headerLabel)
        addSubview(scrollView)
        addSubview(emptyLabel)
        addSubview(banner)
        addSubview(markdownPreview)
        addSubview(imagePreview)
        addSubview(sourceButton)
        addSubview(previewButton)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            headerLabel.heightAnchor.constraint(equalToConstant: 16),

            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            previewButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            previewButton.widthAnchor.constraint(equalToConstant: 22),
            previewButton.heightAnchor.constraint(equalToConstant: 22),

            sourceButton.trailingAnchor.constraint(
                equalTo: previewButton.leadingAnchor, constant: -8,
            ),
            sourceButton.centerYAnchor.constraint(equalTo: previewButton.centerYAnchor),
            sourceButton.widthAnchor.constraint(equalToConstant: 22),
            sourceButton.heightAnchor.constraint(equalToConstant: 22),

            markdownPreview.leadingAnchor.constraint(equalTo: leadingAnchor),
            markdownPreview.trailingAnchor.constraint(equalTo: trailingAnchor),
            markdownPreview.topAnchor.constraint(equalTo: scrollView.topAnchor),
            markdownPreview.bottomAnchor.constraint(equalTo: bottomAnchor),

            imagePreview.leadingAnchor.constraint(equalTo: leadingAnchor),
            imagePreview.trailingAnchor.constraint(equalTo: trailingAnchor),
            imagePreview.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imagePreview.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            banner.topAnchor.constraint(equalTo: scrollView.topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 34),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
        showMessage(L10n.Workspace.editorEmpty)
    }

    private func setupBanner() {
        banner.wantsLayer = true
        banner.layer?.backgroundColor = VSTheme.gutterBackground.cgColor
        banner.layer?.cornerRadius = 6
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true

        bannerLabel.font = .systemFont(ofSize: 11)
        bannerLabel.textColor = VSTheme.editorText
        bannerLabel.lineBreakMode = .byTruncatingTail

        let reload = bannerButton(L10n.Workspace.conflictReload, #selector(onReloadBanner))
        let keep = bannerButton(L10n.Workspace.conflictKeep, #selector(onKeepBanner))
        let compare = bannerButton(L10n.Workspace.conflictCompare, #selector(onCompareBanner))
        bannerButtons = [reload, keep, compare]

        let stack = NSStackView(views: [bannerLabel] + bannerButtons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
        ])
    }

    private func bannerButton(_ title: String, _ action: Selector) -> NSButton {
        let button = PointerButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.bezelStyle = .rounded
        return button
    }

    private func showBanner(deleted: Bool) {
        banner.isHidden = false
        bannerDeleted = deleted
        bannerLabel.stringValue =
            deleted ? L10n.Workspace.deletedBanner : L10n.Workspace.conflictBanner
        for button in bannerButtons { button.isHidden = deleted }
    }

    private func hideBanner() {
        banner.isHidden = true
    }

    @objc private func onReloadBanner() {
        reloadFromDisk()
    }

    @objc private func onKeepBanner() {
        hideBanner()
    }

    @objc private func onCompareBanner() {
        presentComparison()
    }

    private func apply(_ result: FileLoadResult, url: URL, maxBytes: Int) {
        switch result {
        case .text(let loaded):
            document = loaded
            setDirty(false)
            textView.string = loaded.text
            textView.undoManager?.removeAllActions()
            textView.isEditable = true
            ruler?.rebuildLineStarts(loaded.text)
            scrollView.isHidden = false
            emptyLabel.isHidden = true
            updateHeader()
            preparePreview(for: url)
            rebuildHighlightState()
            restorePositionIfNeeded()
            if previewMode == .source, pendingFocus { window?.makeFirstResponder(textView) }
        case .tooLarge:
            resetDocument()
            showMessage(L10n.Workspace.fileTooLarge(limit: maxBytes / 1024 / 1024))
        case .binary:
            resetDocument()
            showMessage(L10n.Workspace.fileBinary)
        case .unsupportedEncoding:
            resetDocument()
            showMessage(L10n.Workspace.fileEncoding)
        case .unreadable(let message):
            resetDocument()
            showMessage(L10n.Workspace.fileUnreadable(message: message))
        }
    }

    private func restorePositionIfNeeded() {
        guard let position = pendingPosition else { return }
        pendingPosition = nil
        let length = (textView.string as NSString).length
        let caret = min(max(position.caret, 0), length)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
        }
        let maxY = max(0, textView.bounds.height - scrollView.contentView.bounds.height)
        let y = min(max(position.scrollY, 0), Double(maxY))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func resetDocument() {
        document = nil
        pendingPosition = nil
        setDirty(false)
        syntaxDefinition = nil
        highlightWorkItem?.cancel()
        hidePreview()
        textView.string = ""
        scrollView.isHidden = true
    }

    // MARK: - Preview

    private func preparePreview(for url: URL) {
        imagePreview.clear()
        imagePreview.isHidden = true
        let isMarkdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        markdownURL = isMarkdown ? url : nil
        sourceButton.isHidden = !isMarkdown
        previewButton.isHidden = !isMarkdown
        previewMode = .source
        updateModeButtons()
        updatePreviewVisibility()
        if let lastPreviewMode { applyPreviewMode(lastPreviewMode) }
    }

    private func showImage(url: URL, generation: Int) {
        document = nil
        markdownURL = nil
        textView.string = ""
        ruler?.rebuildLineStarts("")
        syntaxDefinition = nil
        highlightWorkItem?.cancel()
        sourceButton.isHidden = true
        previewButton.isHidden = true
        markdownPreview.isHidden = true
        imagePreview.clear()
        imagePreview.isHidden = false
        previewMode = .image
        emptyLabel.isHidden = true
        scrollView.isHidden = true
        let limit =
            max(1, ConfigManager.shared.config.workspace.imagePreviewMaxSizeMB) * 1024 * 1024
        Task { [weak self] in
            let result = await ImagePreviewView.load(url: url, maxBytes: limit)
            guard let self, self.loadGeneration == generation else { return }
            self.imagePreview.show(result, maxBytes: limit)
        }
    }

    private func renderMarkdownPreview() {
        guard let markdownURL else { return }
        markdownPreview.render(
            markdown: textView.string,
            baseURL: markdownURL.deletingLastPathComponent(),
        )
    }

    private func updatePreviewVisibility() {
        switch previewMode {
        case .source:
            scrollView.isHidden = document == nil
            markdownPreview.isHidden = true
            imagePreview.isHidden = true
            textView.isEditable = document != nil
        case .markdown:
            scrollView.isHidden = document == nil
            markdownPreview.isHidden = false
            imagePreview.isHidden = true
            textView.isEditable = false
        case .image:
            scrollView.isHidden = true
            markdownPreview.isHidden = true
            imagePreview.isHidden = false
            textView.isEditable = false
        }
    }

    private func hidePreview() {
        markdownURL = nil
        previewMode = .source
        sourceButton.isHidden = true
        previewButton.isHidden = true
        markdownPreview.isHidden = true
        imagePreview.isHidden = true
        imagePreview.clear()
    }

    private func configureModeButton(
        _ button: NSButton, symbol: String, toolTip: String, action: Selector,
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = VSTheme.secondaryText
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func updateModeButtons() {
        sourceButton.contentTintColor =
            previewMode == .source ? VSTheme.text : VSTheme.secondaryText
        previewButton.contentTintColor =
            previewMode == .markdown ? VSTheme.text : VSTheme.secondaryText
    }

    @objc private func onShowSource() {
        guard markdownURL != nil else { return }
        onPreviewModeChange?(.source)
        window?.makeFirstResponder(textView)
        scheduleHighlight(delay: 0)
    }

    @objc private func onShowPreview() {
        guard markdownURL != nil else { return }
        onPreviewModeChange?(.markdown)
    }

    private func showMessage(_ message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        scrollView.isHidden = document != nil
    }

    private func updateHeader() {
        guard let document else { return }
        let marker = isDirty ? "\u{25CF} " : ""
        headerLabel.stringValue = marker + document.url.lastPathComponent
        headerLabel.toolTip = document.url.path
    }

    @objc private func onScrollChanged() {
        ruler?.needsDisplay = true
        scheduleHighlight(delay: 0.05)
        schedulePositionSync()
    }

    private func schedulePositionSync() {
        positionWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let caret = textView.selectedRange().location
            onPositionChange?(caret, Double(scrollView.contentView.bounds.origin.y))
        }
        positionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func textViewDidChangeSelection(_: Notification) {
        schedulePositionSync()
    }

    @objc private func onLanguageChanged() {
        sourceButton.toolTip = L10n.Workspace.source
        previewButton.toolTip = L10n.Workspace.preview
        if document == nil { emptyLabel.stringValue = L10n.Workspace.editorEmpty }
        if !banner.isHidden {
            bannerLabel.stringValue =
                bannerDeleted ? L10n.Workspace.deletedBanner : L10n.Workspace.conflictBanner
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_: Notification) {
        guard document != nil else { return }
        if !isDirty {
            setDirty(true)
            updateHeader()
        }
        ruler?.rebuildLineStarts(textView.string)
        scheduleDraftSnapshot()
        scheduleDirtyRecompute()
        scheduleHighlight(delay: 0.1)
    }

    // MARK: - Dirty state

    private func scheduleDirtyRecompute() {
        dirtyWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.recomputeDirty() }
        dirtyWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func recomputeDirty() {
        guard let document else {
            setDirty(false)
            return
        }
        let next = document.isDirty(currentText: textView.string)
        guard next != isDirty else { return }
        setDirty(next)
        updateHeader()
        if next {
            scheduleDraftSnapshot()
        } else {
            draftWorkItem?.cancel()
            draftStore.delete(for: document.url)
        }
    }

    @objc private func onUndoChange() {
        recomputeDirty()
    }

    // MARK: - Highlight

    private static let maxHighlightLength = 1_000_000
    private static let maxHighlightLines = 20_000
    private static let highlightContextLines = 200

    private func rebuildHighlightState() {
        highlightWorkItem?.cancel()
        guard let document else {
            syntaxDefinition = nil
            return
        }
        let text = textView.string as NSString
        highlightDisabled =
            text.length > Self.maxHighlightLength || lineCount(of: text) > Self.maxHighlightLines
        syntaxDefinition = syntaxProvider.definition(for: document.url)
        if highlightDisabled {
            clearHighlight()
        } else {
            scheduleHighlight(delay: 0)
        }
    }

    private func scheduleHighlight(delay: TimeInterval) {
        highlightWorkItem?.cancel()
        guard syntaxDefinition != nil, !highlightDisabled else { return }
        let item = DispatchWorkItem { [weak self] in self?.applyHighlight() }
        highlightWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func applyHighlight() {
        guard previewMode == .source, let definition = syntaxDefinition, !highlightDisabled,
            let storage = textView.textStorage, storage.length > 0,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            !textView.hasMarkedText()
        else { return }

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil,
        )
        let text = storage.string as NSString
        let range = expandedRange(
            around: charRange, in: text, lines: Self.highlightContextLines,
        )
        guard range.length > 0 else { return }

        let tokens = syntaxProvider.tokens(in: text, range: range, definition: definition)
        let undo = textView.undoManager
        undo?.disableUndoRegistration()
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: VSTheme.editorText, range: range)
        for token in tokens {
            storage.addAttribute(
                .foregroundColor, value: syntaxProvider.color(for: token.kind), range: token.range,
            )
        }
        storage.endEditing()
        undo?.enableUndoRegistration()
        textView.typingAttributes = [
            .font: VSTheme.editorFont(size: 12),
            .foregroundColor: VSTheme.editorText,
        ]
    }

    private func clearHighlight() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let undo = textView.undoManager
        undo?.disableUndoRegistration()
        storage.beginEditing()
        storage.addAttribute(
            .foregroundColor, value: VSTheme.editorText,
            range: NSRange(location: 0, length: storage.length),
        )
        storage.endEditing()
        undo?.enableUndoRegistration()
    }

    private func expandedRange(around range: NSRange, in text: NSString, lines: Int) -> NSRange {
        var start = range.location
        var remaining = lines
        while remaining > 0, start > 0 {
            start = text.lineRange(for: NSRange(location: start - 1, length: 0)).location
            remaining -= 1
        }
        var end = range.location + range.length
        remaining = lines
        while remaining > 0, end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            end = next.location + next.length
            remaining -= 1
        }
        end = min(max(end, start), text.length)
        return NSRange(location: start, length: end - start)
    }

    private func lineCount(of text: NSString) -> Int {
        var lines = 1
        var index = 0
        while index < text.length {
            if text.character(at: index) == 10 { lines += 1 }
            index += 1
        }
        return lines
    }
}
