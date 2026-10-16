import Cocoa

/// Markdown 渲染视图：把语义 intent 翻译成字体与段落样式。
/// `AttributedString(markdown:)` **不带任何字体** —— 直接塞进 NSTextView 会「标题与正文一样大、
/// 加粗不变粗、列表没有项目符号」且不报错;全部工作量就在下面那张 intent → 视觉属性的映射表上。
final class KnowledgeMarkdownView: NSView, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    private func setup() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude,
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude,
        )
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        scrollView.documentView = textView
        // 不显示滚动条:legacy 样式的白色轨道在毛玻璃面板上非常突兀。滚轮与触控板手势
        // 照常可用(NSScrollView 自己处理 scrollWheel,与是否显示 scroller 无关)
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func render(_ markdown: String) {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            return
        }
        let rendered = Self.renderAttributed(Self.neutralizeTables(text)) ?? Self.plainFallback(text)
        textView.textStorage?.setAttributedString(rendered)
        textView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - 渲染

    /// GFM 表格 `AttributedString` 认得却无表格布局,直接给它会把单元格拆成独立段落(七行摊
    /// 成三十行)。故竖线换 U+2502 退回文本,行尾补两个空格强制换行:不补则同段 soft break 折叠成空格
    private static func neutralizeTables(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 else {
                return String(line)
            }
            return line.replacingOccurrences(of: "|", with: "│") + "  "
        }.joined(separator: "\n")
    }

    private static func renderAttributed(_ markdown: String) -> NSAttributedString? {
        guard let parsed = try? AttributedString(
            markdown: markdown, options: .init(interpretedSyntax: .full),
        ) else {
            debugLog("[Knowledge] Markdown 解析失败,降级为纯文本渲染")
            return nil
        }

        let out = NSMutableAttributedString()
        var lastIntent: PresentationIntent?
        var started = false
        for run in parsed.runs {
            let intent = run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]
            let inline = run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
            let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self]
            let text = String(parsed[run.range].characters)
            let attrs = attributes(intent: intent, inline: inline, link: link, text: text)
            // 块级 intent 变化即段界:同一段落会被 inline 属性拆成多个 run,不能每个都补前缀。
            // 换行必须自己补 —— `.full` 语法把段落边界表达在 intent 上,文本里**没有换行字符**,
            // 不补的话标题、列表项、正文会全部挤成一行。
            if intent != lastIntent {
                if started {
                    out.append(NSAttributedString(string: "\n", attributes: attrs))
                }
                if let intent, let lead = prefix(intent) {
                    out.append(NSAttributedString(string: lead, attributes: attrs))
                }
                started = true
            }
            lastIntent = intent
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    private static func plainFallback(_ markdown: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        return NSAttributedString(string: markdown, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: p,
        ])
    }

    // MARK: - intent → 视觉属性

    private static func attributes(
        intent: PresentationIntent?,
        inline: InlinePresentationIntent?,
        link: URL?,
        text: String,
    ) -> [NSAttributedString.Key: Any] {
        // 表格行(竖线已被 neutralizeTables 换成 U+2502)用等宽字体,让分隔符位置稳定。
        // **不做整卡降级** —— 那会把标题、粗体、列表一起变成 Markdown 源码。
        var font = text.contains("│")
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        var color = NSColor.labelColor
        var background: NSColor?
        var spacingBefore: CGFloat = 0
        var spacingAfter: CGFloat = 6
        var headIndent: CGFloat = 0

        if let intent {
            if let level = headerLevel(intent) {
                font = NSFont.boldSystemFont(ofSize: headerSize(level))
                spacingBefore = level == 1 ? 12 : 10
                spacingAfter = 8
            } else if isCodeBlock(intent) {
                font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                background = NSColor.separatorColor.withAlphaComponent(0.22)
                spacingAfter = 4
            } else if isBlockQuote(intent) {
                color = .secondaryLabelColor
                headIndent = 18
            } else if listOrdinal(intent) != nil {
                headIndent = 18
            }
        }

        if let inline {
            if inline.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular)
                background = NSColor.separatorColor.withAlphaComponent(0.22)
            }
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
        }

        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = spacingAfter
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = headIndent

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: p,
        ]
        if let background { attrs[.backgroundColor] = background }
        if let link {
            attrs[.link] = link
            attrs[.foregroundColor] = NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    /// 列表段落的挂牌:无序 `• `、有序 `1. `。非列表返回 nil。
    ///
    /// 有序/无序**不能**看 `listItem(ordinal:)` —— 无序列表的 ordinal 同样是 1,2,3。
    /// 判据在父意图上:`components` 是从根到叶的路径,含 `.orderedList` 才是有序。
    private static func prefix(_ intent: PresentationIntent) -> String? {
        guard let ordinal = listOrdinal(intent) else { return nil }
        let ordered = intent.components.contains(where: { component in
            if case .orderedList = component.kind { return true }
            return false
        })
        return ordered ? "\(ordinal). " : "• "
    }

    /// 遍历组件而非直接遍历 `components` 的元素 —— 那个元素是 `IntentType` 包装,
    /// 真正的枚举在它的 `kind` 上。
    private static func headerLevel(_ intent: PresentationIntent) -> Int? {
        for component in intent.components {
            if case let .header(level) = component.kind { return level }
        }
        return nil
    }

    private static func listOrdinal(_ intent: PresentationIntent) -> Int? {
        for component in intent.components {
            if case let .listItem(ordinal) = component.kind { return ordinal }
        }
        return nil
    }

    private static func isCodeBlock(_ intent: PresentationIntent) -> Bool {
        intent.components.contains(where: { component in
            if case .codeBlock = component.kind { return true }
            return false
        })
    }

    private static func isBlockQuote(_ intent: PresentationIntent) -> Bool {
        intent.components.contains(where: { component in
            if case .blockQuote = component.kind { return true }
            return false
        })
    }

    private static func headerSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15
        case 3: 13.5
        default: 13
        }
    }

    // MARK: - 链接

    func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
