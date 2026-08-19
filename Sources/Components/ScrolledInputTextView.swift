import Cocoa

// MARK: - InnerTextView

/// 内部 NSTextView — 独立 undoManager，避免污染全局撤销栈
private final class InnerTextView: NSTextView {
    private let _undoManager = UndoManager()
    override var undoManager: UndoManager? {
        _undoManager
    }
}

// MARK: - ScrolledInputTextView

/// 自包含可滚动多行输入框组件
/// 内部管理 NSScrollView + InnerTextView，对外暴露统一的 style / clear / scroll / setCursor API
public final class ScrolledInputTextView: NSView {
    // MARK: - Subviews

    private let scrollView: NSScrollView = {
        let s = NSScrollView()
        s.hasVerticalScroller = false
        s.borderType = .noBorder
        s.scrollerStyle = .overlay
        s.autohidesScrollers = true
        s.verticalScroller?.controlSize = .small
        s.drawsBackground = false
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    public let textView: NSTextView = {
        let tv = InnerTextView(frame: .zero)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude,
        )
        return tv
    }()

    // MARK: - Height management

    /// 最小高度（仅当 maxHeight 非 nil 时生效，内容不足时保持此高度）
    public var minHeight: CGFloat = 0 {
        didSet { updateContentHeight() }
    }

    /// 最大高度（nil = 不限制，非 nil 时内容从 minHeight 起随文本增长到此值后停止）
    public var maxHeight: CGFloat? {
        didSet { updateContentHeight() }
    }

    private var _heightConstraint: NSLayoutConstraint?

    private func updateContentHeight() {
        guard let maxH = maxHeight else { return }
        let h = min(max(contentHeight, minHeight), maxH)
        if let c = _heightConstraint {
            if abs(c.constant - h) > 1 {
                c.constant = h
            }
        } else {
            _heightConstraint = heightAnchor.constraint(equalToConstant: h)
            _heightConstraint?.isActive = true
        }
    }

    // MARK: - Style

    private var _style: InputViewStyle = .init()

    /// 获取/设置样式 — 设置时全量应用
    public var style: InputViewStyle {
        get { _style }
        set { applyStyle(newValue) }
    }

    // MARK: - Content proxy

    /// 文本内容（直接代理到内部 NSTextView）
    public var string: String {
        get { textView.string }
        set {
            textView.string = newValue
            updateContentHeight()
        }
    }

    /// 是否可编辑（直接代理）
    public var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    // MARK: - Init

    public init(style: InputViewStyle = InputViewStyle()) {
        _style = style
        super.init(frame: .zero)
        wantsLayer = true
        setupScrollView()
        applyStyle(style)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setupScrollView() {
        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Style application

    private func applyStyle(_ style: InputViewStyle) {
        if let bg = style.backgroundColor {
            scrollView.drawsBackground = true
            scrollView.backgroundColor = bg
            style.apply(to: textView)
        } else {
            scrollView.drawsBackground = false
            style.apply(to: textView)
        }

        scrollView.hasVerticalScroller = style.showsVerticalScroller

        if let border = style.border {
            layer?.borderColor = border.color.cgColor
            layer?.borderWidth = border.width
            layer?.cornerRadius = border.cornerRadius
        } else {
            layer?.borderWidth = 0
            layer?.cornerRadius = 0
        }
    }

    // MARK: - API: Clear

    public func clear() {
        textView.string = ""
        updateContentHeight()
    }

    // MARK: - API: Undo

    /// 撤销
    public func undo() {
        textView.undoManager?.undo()
    }

    /// 重做
    public func redo() {
        textView.undoManager?.redo()
    }

    /// 清空撤销栈
    public func clearUndo() {
        textView.undoManager?.removeAllActions()
    }

    // MARK: - API: Edit

    public func cut() {
        textView.cut(nil)
    }

    public func copy() {
        textView.copy(nil)
    }

    public func paste() {
        textView.paste(nil)
    }

    public func selectAll() {
        textView.selectAll(nil)
    }

    public func delete() {
        textView.delete(nil)
    }

    public func insertNewline() {
        textView.insertNewline(nil)
    }

    public func insertText(_ string: String) {
        textView.insertText(string, replacementRange: NSRange(location: textView.string.count, length: 0))
    }

    /// 选中指定范围
    public func select(range: NSRange) {
        textView.setSelectedRange(range)
    }

    // MARK: - API: Append

    /// 追加文本（使用当前样式属性），自动滚到底部
    public func append(_ text: String) {
        append(text, attributes: nil)
    }

    /// 追加文本（使用指定属性），自动滚到底部
    public func append(_ text: String, attributes: [NSAttributedString.Key: Any]?) {
        let attrs = attributes ?? [
            .font: _style.font,
            .foregroundColor: _style.textColor,
        ]
        textView.textStorage?.append(NSAttributedString(string: text, attributes: attrs))
        textView.scrollToEndOfDocument(nil)
        updateContentHeight()
    }

    // MARK: - API: Content Height

    /// 文本内容实际高度（含 inset）
    public var contentHeight: CGFloat {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer
        else { return 0 }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return used.height + textView.textContainerInset.height * 2
    }

    // MARK: - API: Scroll

    public func scroll(to position: ScrollPosition) {
        switch position {
        case .top:
            textView.scrollToBeginningOfDocument(nil)
        case .bottom:
            textView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - API: SetCursor

    public func setCursor(to position: CursorPosition) {
        let count = textView.string.count
        let target: Int = switch position {
        case .start:
            0
        case .end:
            count
        case let .index(n):
            max(0, min(n, count))
        }

        textView.setSelectedRange(NSRange(location: target, length: 0))
    }
}
