import Cocoa

/// Generic overlay view: semi-transparent background + centered content (spinner / error message)
///
/// Three states:
/// - ``showLoading()`` — spinner animation
/// - ``showError(_:)`` — red error message
/// - ``hide()`` — hide the overlay
///
/// Usage example:
/// ```swift
/// let overlay = OverlayView()
/// contentView.addSubview(overlay)
/// // Constrain to fill the target area
/// overlay.showLoading()
/// overlay.showError("Request failed")
/// overlay.hide()
/// ```
public final class OverlayView: NSView {
    // MARK: - Mode

    public enum Mode {
        case loading
        case error
    }

    // MARK: - Subviews

    private let spinner = LoadingSpinner()
    private let messageLabel = NSTextField(labelWithString: "")

    // MARK: - State

    public private(set) var mode: Mode = .loading
    public var isVisible: Bool {
        !isHidden
    }

    // MARK: - Init

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = CGColor(
            red: 0xF5 / 0xFF, green: 0xF5 / 0xFF, blue: 0xF5 / 0xFF, alpha: 0.72,
        )
        layer?.cornerRadius = 4

        messageLabel.font = NSFont.systemFont(ofSize: 14)
        messageLabel.textColor = NSColor.systemRed
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, messageLabel])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Public API

    public func showLoading() {
        mode = .loading
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        isHidden = false
    }

    public func showError(_ message: String) {
        mode = .error
        spinner.isHidden = true
        spinner.stopAnimation(nil)
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        isHidden = false
    }

    public func hide() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        messageLabel.stringValue = ""
        isHidden = true
    }
}
