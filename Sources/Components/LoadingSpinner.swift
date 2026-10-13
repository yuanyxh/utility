import Cocoa

/// Generic loading indicator — a preconfigured NSProgressIndicator subclass
///
/// Automatically sets the `.spinning` style + `isDisplayedWhenStopped = false`.
/// Icon color, size, and layout are controlled externally:
///
/// ```swift
/// let spinner = LoadingSpinner()
/// spinner.contentTintColor = .systemBlue
/// spinner.controlSize = .small
/// spinner.translatesAutoresizingMaskIntoConstraints = false
/// spinner.startAnimation(nil)
/// ```
public final class LoadingSpinner: NSProgressIndicator {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .spinning
        controlSize = .regular
        isDisplayedWhenStopped = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        style = .spinning
        controlSize = .regular
        isDisplayedWhenStopped = false
    }
}
