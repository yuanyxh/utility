import Cocoa

/// 可滚动语种选择器 — 用 NSScrollView + NSStackView 实现
final class LanguagePicker: NSObject {
    let button: NSButton
    private let popover = NSPopover()
    private let scrollView: NSScrollView = {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.borderType = .noBorder
        s.scrollerStyle = .overlay
        s.wantsLayer = true
        s.layer?.cornerRadius = 1
        s.translatesAutoresizingMaskIntoConstraints = false
        // 细滚动条
        s.verticalScroller?.controlSize = .mini
        return s
    }()
    private let stackView: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.spacing = 0
        s.alignment = .leading
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    private let languages: [(code: String, name: String)]
    private var onSelect: ((String, String) -> Void)?

    var selectedCode: String = "auto"

    init(title: String, languages: [(code: String, name: String)], selectionChanged: @escaping (String, String) -> Void) {
        self.languages = languages
        self.onSelect = selectionChanged

        button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 11)
        button.controlSize = .small
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        super.init()
        button.target = self
        button.action = #selector(showPopover)

        setupItems()
    }

    private func setupItems() {
        // 上下 padding
        let topPad = NSView()
        topPad.heightAnchor.constraint(equalToConstant: 4).isActive = true
        stackView.addArrangedSubview(topPad)

        for (_, name) in languages {
            let item = NSButton(title: name, target: self, action: #selector(selectLanguage(_:)))
            item.setButtonType(.momentaryPushIn)
            item.isBordered = false
            item.font = NSFont.systemFont(ofSize: 12)
            item.alignment = .left
            item.contentTintColor = .labelColor
            // 整行可点+左侧间距
            item.bezelStyle = .inline
            if let cell = item.cell as? NSButtonCell {
                cell.backgroundStyle = .raised
            }
            // 用 contentInsets 或直接加 leading 约束实现左间距
            let container = NSView()
            container.addSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                item.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                item.topAnchor.constraint(equalTo: container.topAnchor),
                item.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            stackView.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            container.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }

        // 底部 padding
        let bottomPad = NSView()
        bottomPad.heightAnchor.constraint(equalToConstant: 4).isActive = true
        stackView.addArrangedSubview(bottomPad)

        scrollView.documentView = stackView
        scrollView.widthAnchor.constraint(equalToConstant: 150).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: min(CGFloat(languages.count) * 22, 264)).isActive = true

        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = scrollView
        popover.behavior = .transient
    }

    /// 重置滚动位置到顶部（每次翻译窗口打开时调用）
    func resetScroll() {
        scrollView.documentView?.scroll(NSPoint(x: 0, y: 0))
    }

    @objc private func showPopover(_ sender: NSButton) {
        resetScroll()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func selectLanguage(_ sender: NSButton) {
        // 找到 sender 所在的 container
        guard let container = sender.superview else { return }
        guard let idx = stackView.arrangedSubviews.firstIndex(of: container) else { return }
        let lang = languages[idx]
        selectedCode = lang.code
        button.title = lang.name
        onSelect?(lang.code, lang.name)
        popover.performClose(nil)
    }
}
