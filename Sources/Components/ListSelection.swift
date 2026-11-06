import Cocoa

/// Ignores clicks on empty list space; AppKit would otherwise clear the selection
/// while the store-backed selection state stays unchanged, so the row lost its style.
class PersistentSelectionTableView: NSTableView {
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard row(at: point) >= 0 else { return }
        super.mouseDown(with: event)
    }
}
