import Cocoa

/// Status strip under the sub-terminal area; shows the current git branch on the left.
@MainActor
final class WorkspaceStatusBar: NSView {
    static let height: CGFloat = 22

    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.sidebarBackground.cgColor

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = VSTheme.separator.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        branchIcon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil,
        )
        branchIcon.contentTintColor = VSTheme.secondaryText
        branchIcon.imageScaling = .scaleProportionallyDown
        branchIcon.isHidden = true
        branchIcon.translatesAutoresizingMaskIntoConstraints = false

        branchLabel.font = .systemFont(ofSize: 11)
        branchLabel.textColor = VSTheme.secondaryText
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.isHidden = true
        branchLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(branchIcon)
        addSubview(branchLabel)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            branchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            branchIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchIcon.widthAnchor.constraint(equalToConstant: 12),
            branchIcon.heightAnchor.constraint(equalToConstant: 12),

            branchLabel.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 4),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -10,
            ),
        ])
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func setBranch(_ branch: String?) {
        let name = branch ?? ""
        branchLabel.stringValue = name
        branchLabel.toolTip = name.isEmpty ? nil : name
        branchIcon.isHidden = name.isEmpty
        branchLabel.isHidden = name.isEmpty
    }
}
