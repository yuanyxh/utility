import Cocoa

// MARK: - InnerTextView

/// Inner NSTextView — independent undoManager to avoid polluting the global undo stack
private final class InnerTextView: NSTextView {
    private let _undoManager = UndoManager()
    override var undoManager: UndoManager? {
        _undoManager
    }
}

// MARK: - ScrolledInputTextView

/// Self-contained scrollable multi-line input component
/// Manages NSScrollView + InnerTextView internally, exposing a unified style / clear / scroll / setCursor API
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

    /// Minimum height (only takes effect when maxHeight is non-nil; keeps this height when content is insufficient)
    public var minHeight: CGFloat = 0 {
        didSet { updateContentHeight() }
    }

    /// Maximum height (nil = unlimited; when non-nil, content grows from minHeight with the text up to this value then stops)
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

    /// Get/set the style — setting applies it fully
    public var style: InputViewStyle {
        get { _style }
        set { applyStyle(newValue) }
    }

    // MARK: - Content proxy

    /// Text content (directly proxied to the inner NSTextView)
    public var string: String {
        get { textView.string }
        set {
            textView.string = newValue
            updateContentHeight()
        }
    }

    /// Whether editable (direct proxy)
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

    // MARK: - Layout

    /// Keep the document view width consistent with the scroll area.
    ///
    /// On a real device we diagnosed this component's `textView.frame.width` stuck at 0 (height normal),
    /// while `textContainer` width was already 596 — layout was fine but the drawable area was 0 wide,
    /// so the text was completely invisible. We sync explicitly here rather than relying on AppKit's implicit timing.
    override public func layout() {
        super.layout()
        let width = scrollView.contentSize.width
        guard width > 0, textView.frame.width != width else { return }
        textView.setFrameSize(NSSize(
            width: width,
            height: max(textView.frame.height, scrollView.contentSize.height),
        ))
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

    /// Undo
    public func undo() {
        textView.undoManager?.undo()
    }

    /// Redo
    public func redo() {
        textView.undoManager?.redo()
    }

    /// Clear the undo stack
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

    /// Select the specified range
    public func select(range: NSRange) {
        textView.setSelectedRange(range)
    }

    // MARK: - API: Append

    /// Append text (using the current style attributes), auto-scroll to the bottom
    public func append(_ text: String) {
        append(text, attributes: nil)
    }

    /// Append text (using the specified attributes), auto-scroll to the bottom
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

    /// Actual text content height (including inset)
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
