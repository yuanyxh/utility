import Cocoa

/// 圆角描边容器：卡片的视觉边界。
private final class BorderBoxView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder _: NSCoder) {
        nil
    }
}

/// 自绘强调按钮：背景由 layer/draw 自己控制，不随窗口 key 状态被系统压暗。
private final class KnowledgeActionButton: NSButton {
    var fillColor: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    var pressedColor: NSColor = .systemRed.withAlphaComponent(0.72)
    var textColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    private var titleFont: NSFont {
        .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: titleFont])
        return NSSize(width: max(36, size.width + 16), height: max(22, size.height + 6))
    }

    override func draw(_: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 5,
            yRadius: 5,
        )
        let color = isEnabled ? (isHighlighted ? pressedColor : fillColor) : fillColor.withAlphaComponent(0.35)
        color.setFill()
        path.fill()

        let labelColor = isEnabled ? textColor : textColor.withAlphaComponent(0.65)
        let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: labelColor]
        let size = (title as NSString).size(withAttributes: attrs)
        let point = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
        )
        (title as NSString).draw(at: point, withAttributes: attrs)
    }

    func setStyledTitle(_ text: String) {
        title = text
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

/// 知识面板：一张卡 + 一排按钮。零引用 PanelManager，只经 EventBus 收发 show/close。
public final class KnowledgePanelController: NSWindowController {
    static let kindTopic = "topic"

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let topicView = KnowledgeMarkdownView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let container = BorderBoxView()

    private let knownButton = NSButton()
    private let dislikeButton = KnowledgeActionButton()
    private let likeButton = NSButton()
    private let copyButton = NSButton()
    private let closeButton = NSButton()

    private var currentCard: KnowledgeCard?
    private var autoCloseTimer: Timer?
    /// 只有定时弹出的这一张参与自动关闭:聚焦期间停表,失焦后从 0 重新计时。
    private var autoCloseEligible = false

    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false,
        )
        panel.level = NSWindow.Level.floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // 固定在右下角的卡片:不拖走(拖走了下次也弹回原位,反而费解),也不显示窗口控制
        // —— 关闭有底部按钮与 ESC 两条路。`.titled` 必须留着,窗口圆角来自它。
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 320, height: 400)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear

        super.init(window: panel)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWindowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: panel,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWindowResignKey),
            name: NSWindow.didResignKeyNotification, object: panel,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onAppResignActive),
            name: NSApplication.didResignActiveNotification, object: nil,
        )
    }

    required init?(coder _: NSCoder) {
        nil
    }

    deinit {
        autoCloseTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        guard let panel = window, let content = panel.contentView else { return }

        // 内容一律裁在窗口内:NSView 默认不裁剪,某个视图一旦超出约束就会直接画到桌面上,
        // 窗口看着像"变大了"(长副标题顶破 headerRow 时就是这个症状)
        content.clipsToBounds = true

        // 半透明用材质而不是窗口 alphaValue(后者会连文字一起淡)。`.popover` 是实测透射最强的
        // material,再叠 backdrop 自己的 alphaValue 压掉 a=1.0 时的白蒙层,只淡背景层、不动上层文字
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.alphaValue = 0.85
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backdrop, positioned: .below, relativeTo: nil)

        titleLabel.font = .boldSystemFont(ofSize: 13)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 压缩阻力必须设在 **label 自身**:NSStackView 不会把它传播给 arranged subviews,
        // 设在 stack 上时那条 1100pt 的副标题会拒绝压缩,把整个头部横向顶出窗口。
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let headerRow = NSStackView(views: [titleStack, headerSpacer])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerRow)

        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(container)
        topicView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topicView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        configure(knownButton, L10n.Knowledge.known, #selector(onKnown))
        configure(likeButton, L10n.Knowledge.like, #selector(onLike))
        configure(copyButton, L10n.Knowledge.copy, #selector(onCopy))
        configure(closeButton, L10n.Knowledge.close, #selector(onClose))
        // 踩是破坏性操作:自绘红色背景,失焦时也不会被系统压暗;排在赞之后,避免误点
        dislikeButton.target = self
        dislikeButton.action = #selector(onDislike)
        dislikeButton.controlSize = .small
        dislikeButton.setStyledTitle(L10n.Knowledge.dislike)

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [
            buttonSpacer, knownButton, likeButton, dislikeButton,
            copyButton, closeButton,
        ])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttonRow)

        let padding: CGFloat = 12
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            headerRow.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
            headerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            headerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),

            container.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 10),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            container.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -10),

            topicView.topAnchor.constraint(equalTo: container.topAnchor),
            topicView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topicView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topicView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding),
        ])

        refreshTitles()
        show(card: nil)
    }

    private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    // MARK: - 取卡与渲染

    /// 当前有没有卡 —— service 据此决定要不要立刻补货。
    var hasCard: Bool {
        currentCard != nil
    }

    /// 主题的「踩」跳主题：排除当前主题后重取,避免在同一个主题里原地打转。
    private func advance(excludingCurrentTopic: Bool = false) {
        let knowledge = ConfigManager.shared.config.knowledge
        let card: KnowledgeCard? = if excludingCurrentTopic, let topicID = currentCard?.topicID {
            KnowledgeStore.shared.nextCard(
                kind: Self.kindTopic,
                excludingTopic: topicID,
                showReviewed: knowledge.showReviewedCards,
                maxShown: knowledge.maxShownPerCard,
            )
        } else {
            KnowledgeStore.shared.nextCard(
                kind: Self.kindTopic,
                showReviewed: knowledge.showReviewedCards,
                maxShown: knowledge.maxShownPerCard,
            )
        }
        show(card: card)
    }

    private func show(card: KnowledgeCard?) {
        guard let card else {
            currentCard = nil
            topicView.render("")
            emptyLabel.stringValue = L10n.Knowledge.empty
            emptyLabel.isHidden = false
            titleLabel.stringValue = L10n.Knowledge.title
            subtitleLabel.stringValue = ""
            resetActionButtons()
            updateButtonState()
            debugLog("[Knowledge] 面板空态: 池中没有未读卡")
            NotificationCenter.default.post(name: .knowledgeNeedsRefill, object: nil)
            return
        }
        currentCard = card
        emptyLabel.isHidden = true
        topicView.render(renderText(card))
        titleLabel.stringValue = card.title
        subtitleLabel.stringValue = subtitle(for: card)
        resetActionButtons()
        updateButtonState()
    }

    private func subtitle(for card: KnowledgeCard) -> String {
        var parts: [String] = []
        if !card.subtitle.isEmpty { parts.append(card.subtitle) }
        if !card.theme.isEmpty { parts.append(card.theme) }
        if !card.topicKind.isEmpty { parts.append(kindLabel(card.topicKind)) }
        return parts.joined(separator: " · ")
    }

    private func kindLabel(_ kind: String) -> String {
        kind == "trend" ? L10n.Knowledge.kindTrend : L10n.Knowledge.kindPrinciple
    }

    private func renderText(_ card: KnowledgeCard) -> String {
        var text = card.body
        if !card.evidenceURLs.isEmpty {
            text += "\n\n---\n\n**\(L10n.Knowledge.sources)**\n\n"
            text += card.evidenceURLs.prefix(8)
                .map { "- <\($0)>" }
                .joined(separator: "\n")
        }
        return text
    }

    private func cardText(_ card: KnowledgeCard) -> String {
        var text = card.title + "\n\n" + card.body
        if !card.evidenceURLs.isEmpty {
            text += "\n\n---\n" + L10n.Knowledge.sources + ":\n"
            text += card.evidenceURLs.map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }

    private func resetActionButtons() {
        likeButton.title = L10n.Knowledge.like
        likeButton.isEnabled = true
        dislikeButton.setStyledTitle(L10n.Knowledge.dislike)
    }

    private func updateButtonState() {
        let has = currentCard != nil
        for button in [knownButton, dislikeButton, likeButton, copyButton] {
            button.isEnabled = has
        }
    }

    // MARK: - 按钮

    @objc private func onKnown() {
        mark("known")
    }

    @objc private func onLike() {
        guard let card = currentCard else { return }
        disarmAutoClose()
        let knowledge = ConfigManager.shared.config.knowledge
        if knowledge.saveLikedMarkdown, !saveLikedCard(card, config: knowledge) {
            likeButton.title = L10n.Knowledge.saveFailed
            return
        }
        KnowledgeStore.shared.markStatus(cardID: card.id, status: "liked")
        likeButton.title = knowledge.saveLikedMarkdown
            ? L10n.Knowledge.likedSaved
            : L10n.Knowledge.liked
        likeButton.isEnabled = false
        debugLog("[Knowledge] 点赞: card=\(card.id) saved=\(knowledge.saveLikedMarkdown)")
    }

    @objc private func onDislike() {
        mark("disliked", skipTopic: true)
    }

    private func mark(_ status: String, skipTopic: Bool = false) {
        disarmAutoClose()
        if let card = currentCard {
            KnowledgeStore.shared.markStatus(cardID: card.id, status: status)
            debugLog("[Knowledge] 按钮 \(status): card=\(card.id)")
        }
        advance(excludingCurrentTopic: skipTopic)
    }

    private func saveLikedCard(_ card: KnowledgeCard, config: KnowledgeConfig) -> Bool {
        let raw = config.likedSaveDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir: String
        if raw.isEmpty {
            guard let notes = PythonScriptRunner.resolvedNotesDir() else {
                debugLog("[Knowledge] 保存点赞卡失败: notes 根目录未配置")
                return false
            }
            dir = URL(fileURLWithPath: notes, isDirectory: true)
                .appendingPathComponent("知识卡片", isDirectory: true).path
        } else {
            dir = (raw as NSString).expandingTildeInPath
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let slug = card.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
        let filename = "\(stamp)_\(slug.isEmpty ? "card-\(card.id)" : slug).md"
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: url.path) else { return true }
        var text = "---\ntitle: \"\(card.title)\"\ntheme: \"\(card.theme)\"\n"
        text += "kind: \"\(card.topicKind)\"\ncard_id: \(card.id)\nliked_at: \(stamp)\n"
        text += "---\n\n# \(card.title)\n\n\(card.body)\n"
        if !card.evidenceURLs.isEmpty {
            text += "\n## \(L10n.Knowledge.sources)\n\n"
            text += card.evidenceURLs.prefix(8)
                .map { "- <\($0)>" }
                .joined(separator: "\n")
            text += "\n"
        }
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            debugLog("[Knowledge] 已保存点赞卡: \(url.path)")
            return true
        } catch {
            debugLog("[Knowledge] 保存点赞卡失败: \(error)")
            return false
        }
    }

    @objc private func onCopy() {
        guard let card = currentCard else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cardText(card), forType: .string)
        copyButton.title = L10n.Knowledge.copied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton.title = L10n.Knowledge.copy
        }
    }

    @objc private func onClose() {
        EventBus.shared.publish(PanelEvent.requestClose, payload: self)
    }

    // MARK: - 自动关闭

    /// 手动打开不加自动关闭；只有定时弹出的卡才需要它。
    /// 聚焦中(窗口 key)不起表:用户正在看,失焦时会重新从 0 开始。
    private func armAutoClose(force: Bool = false) {
        disarmAutoClose()
        if !force, window?.isKeyWindow == true { return }
        let seconds = ConfigManager.shared.config.knowledge.autoCloseSeconds
        guard seconds > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            self?.closePanel()
        }
        // 必须 .common mode:默认 mode 下拖窗口、开菜单时 timer 会被挂起,面板就不关了
        RunLoop.main.add(timer, forMode: .common)
        autoCloseTimer = timer
    }

    private func disarmAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
    }

    /// 用户点进面板 —— 聚焦期间不应自动关闭。
    @objc private func onWindowBecameKey() {
        guard autoCloseEligible else { return }
        disarmAutoClose()
    }

    /// 失焦后从 0 重新计时：即使弹出时已经计了一半，也要给足完整阅读时间。
    @objc private func onWindowResignKey() {
        guard autoCloseEligible, window?.isVisible == true else { return }
        armAutoClose()
    }

    /// nonactivatingPanel 切到其他 app 时不一定走 resignKey,应用失活同样视为失焦。
    @objc private func onAppResignActive() {
        guard autoCloseEligible, window?.isVisible == true else { return }
        armAutoClose(force: true)
    }

    // MARK: - 显示

    /// 固定贴在屏幕可见区右下角 —— visibleFrame 已排除菜单栏与 Dock。
    private func positionWindow() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        // 垂直方向**不留**边距:visibleFrame.minY 已经排掉了 Dock(实测 80pt),再叠一层
        // 16pt 边距会让面板看起来浮在半空。水平方向留 16pt 是因为右边缘没有系统保留区
        window.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - window.frame.width - 16,
            y: screen.visibleFrame.minY,
        ))
    }

    private func refreshTitles() {
        knownButton.title = L10n.Knowledge.known
        dislikeButton.setStyledTitle(L10n.Knowledge.dislike)
        likeButton.title = L10n.Knowledge.like
        copyButton.title = L10n.Knowledge.copy
        closeButton.title = L10n.Knowledge.close
        emptyLabel.stringValue = L10n.Knowledge.empty
        if let card = currentCard {
            titleLabel.stringValue = card.title
            subtitleLabel.stringValue = subtitle(for: card)
        } else {
            titleLabel.stringValue = L10n.Knowledge.title
        }
    }

    @objc private func onLanguageChanged() {
        refreshTitles()
    }

    /// 定时自动弹：不 makeKey、不 activate —— PanelManager 的 didResignKey 路径不会触发,
    /// 自动关闭完全靠 armAutoClose 的 timer；用户点进面板(窗口 becomeKey)时停表,失焦后重起。
    func showAuto() {
        autoCloseEligible = true
        positionWindow()
        window?.orderFront(nil)
        advance()
        armAutoClose()
    }

    /// 立即取下一张（菜单项「立即补货」后刷新用）。
    func reloadCurrent() {
        advance()
    }
}

// MARK: - PanelProtocol

extension KnowledgePanelController: PanelProtocol {
    var panelID: String {
        "knowledge"
    }

    var panelWindow: NSWindow? {
        window
    }

    var isPanelVisible: Bool {
        window?.isVisible ?? false
    }

    /// 知识卡是「阅读」场景:点面板外部不关,便于边看边去别的窗口查资料(关闭走底部按钮或 ESC)。
    /// 定时弹出的那张不受影响:它非激活 orderFront、从不 becomeKey,自动关仍由 armAutoClose 管。
    var closesOnResignKey: Bool {
        false
    }

    func showPanel(context _: [String: Any]?) {
        autoCloseEligible = false
        disarmAutoClose()
        if !isPanelVisible { positionWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if currentCard == nil { advance() }
    }

    func closePanel() {
        autoCloseEligible = false
        disarmAutoClose()
        window?.orderOut(nil)
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            EventBus.shared.publish(PanelEvent.requestClose, payload: self)
            return true
        }
        return false
    }
}
