import Cocoa

/// 44pt icon column that switches the right pane between files and git.
@MainActor
final class WorkspaceActivityBar: NSView {
    enum Mode {
        case files
        case git
    }

    var onSelect: ((Mode) -> Void)?
    private(set) var mode: Mode = .files {
        didSet { updateSelection() }
    }

    private let filesButton = PointerButton()
    private let gitButton = PointerButton()
    private let gitBadge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.sidebarBackground.cgColor
        configure(filesButton, symbol: "folder", toolTip: L10n.Workspace.filesPlaceholder)
        configure(gitButton, symbol: "arrow.triangle.branch", toolTip: "Git")
        filesButton.target = self
        filesButton.action = #selector(selectFiles)
        gitButton.target = self
        gitButton.action = #selector(selectGit)

        gitBadge.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        gitBadge.textColor = .white
        gitBadge.alignment = .center
        gitBadge.wantsLayer = true
        gitBadge.layer?.backgroundColor = VSTheme.badge.cgColor
        gitBadge.layer?.cornerRadius = 6.5
        gitBadge.isHidden = true
        gitBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(filesButton)
        addSubview(gitButton)
        addSubview(gitBadge)
        NSLayoutConstraint.activate([
            filesButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            filesButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            filesButton.widthAnchor.constraint(equalToConstant: 32),
            filesButton.heightAnchor.constraint(equalToConstant: 32),

            gitButton.topAnchor.constraint(equalTo: filesButton.bottomAnchor, constant: 14),
            gitButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            gitButton.widthAnchor.constraint(equalToConstant: 32),
            gitButton.heightAnchor.constraint(equalToConstant: 32),

            gitBadge.centerXAnchor.constraint(equalTo: gitButton.trailingAnchor, constant: -4),
            gitBadge.centerYAnchor.constraint(equalTo: gitButton.topAnchor, constant: 5),
            gitBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 13),
            gitBadge.heightAnchor.constraint(equalToConstant: 13),
        ])
        updateSelection()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    private func configure(_ button: NSButton, symbol: String, toolTip: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = VSTheme.secondaryText
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    func setMode(_ mode: ListMode) {
        self.mode = mode == .git ? .git : .files
    }

    func setGitCount(_ count: Int) {
        guard count > 0 else {
            gitBadge.isHidden = true
            return
        }
        gitBadge.stringValue = count > 99 ? "99+" : "\(count)"
        gitBadge.isHidden = false
    }

    private func updateSelection() {
        filesButton.contentTintColor = mode == .files ? VSTheme.text : VSTheme.secondaryText
        gitButton.contentTintColor = mode == .git ? VSTheme.text : VSTheme.secondaryText
    }

    @objc private func selectFiles() {
        onSelect?(.files)
    }

    @objc private func selectGit() {
        onSelect?(.git)
    }
}
