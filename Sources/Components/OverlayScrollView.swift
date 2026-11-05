import Cocoa

/// Keeps scrollers in overlay mode with autohide, so lists never show a
/// permanent track even when the scroll view was configured before joining a
/// window (where AppKit re-tiles against the window's scroller style).
final class OverlayScrollView: NSScrollView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOverlayStyle()
    }

    override func tile() {
        super.tile()
        applyOverlayStyle()
    }

    private func applyOverlayStyle() {
        if scrollerStyle != .overlay {
            scrollerStyle = .overlay
        }
        if !autohidesScrollers {
            autohidesScrollers = true
        }
    }
}
