import Cocoa

/// Main terminal pane: one SwiftTerm view at a time plus the empty-state label.
@MainActor
final class TerminalHostView: NSView, WorkspacePanel {
    let panelID = PanelID.mainTerminal
    var focusTarget: NSView? { terminalView }

    private let emptyLabel = NSTextField(labelWithString: L10n.Terminal.empty)
    private(set) var terminalView: NSView?
    private var lastRendered: TerminalUIState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.windowBackground.cgColor
        emptyLabel.textColor = VSTheme.secondaryText
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func render(_ snapshot: WorkspaceSnapshot) {
        guard snapshot.terminals != lastRendered else { return }
        lastRendered = snapshot.terminals
        if terminalView == nil {
            emptyLabel.isHidden = snapshot.terminals.mainSessionID != nil
        }
    }

    var terminalContentSize: NSSize {
        NSSize(width: max(1, bounds.width - 20), height: max(1, bounds.height - 20))
    }

    func attach(_ view: NSView) {
        emptyLabel.isHidden = true
        guard terminalView !== view else { return }
        terminalView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        terminalView = view
        focus()
    }

    func focus() {
        guard let view = terminalView else { return }
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(view)
        }
    }

    func detach() {
        terminalView?.removeFromSuperview()
        terminalView = nil
        emptyLabel.stringValue = L10n.Terminal.empty
        emptyLabel.isHidden = false
    }

    func showEmptyState(message: String? = nil) {
        terminalView?.removeFromSuperview()
        terminalView = nil
        emptyLabel.stringValue = message ?? L10n.Terminal.empty
        emptyLabel.isHidden = false
    }

    func refreshLocalizedText() {
        if terminalView == nil { emptyLabel.stringValue = L10n.Terminal.empty }
    }
}
