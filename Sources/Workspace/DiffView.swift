import Cocoa

/// Read-only unified diff with per-line colours.
@MainActor
final class DiffView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = OverlayScrollView()
    private let textView = NSTextView()
    private let emptyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.editorBackground.cgColor
        setup()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func show(diff: String, path: String) {
        titleLabel.stringValue = (path as NSString).lastPathComponent
        titleLabel.toolTip = path
        if diff.contains("Binary files ") && !diff.contains("@@") {
            textView.string = ""
            scrollView.isHidden = true
            emptyLabel.stringValue = L10n.Workspace.gitBinary
            emptyLabel.isHidden = false
            return
        }
        let font = VSTheme.editorFont(size: 12)
        let attributed = NSMutableAttributedString()
        for line in diff.components(separatedBy: "\n") {
            attributed.append(
                NSAttributedString(
                    string: line + "\n",
                    attributes: [.font: font, .foregroundColor: color(for: line)],
                ),
            )
        }
        textView.textStorage?.setAttributedString(attributed)
        scrollView.isHidden = false
        emptyLabel.isHidden = true
    }

    func showEmpty(_ message: String) {
        titleLabel.stringValue = ""
        textView.string = ""
        scrollView.isHidden = true
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    func clear() {
        showEmpty(L10n.Workspace.gitSelectFile)
    }

    private func color(for line: String) -> NSColor {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ")
            || line.hasPrefix("index ") || line.hasPrefix("new file")
            || line.hasPrefix("deleted file") || line.hasPrefix("Binary files")
        {
            return VSTheme.secondaryText
        }
        if line.hasPrefix("@@") { return VSTheme.syntaxKey }
        if line.hasPrefix("+") { return VSTheme.success }
        if line.hasPrefix("-") { return VSTheme.error }
        return VSTheme.editorText
    }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = VSTheme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = VSTheme.editorFont(size: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude,
        )
        textView.translatesAutoresizingMaskIntoConstraints = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = VSTheme.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
        clear()
    }
}
