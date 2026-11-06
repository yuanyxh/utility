import Cocoa

/// Views that should show the pointing hand while hovered.
@MainActor
protocol PointerClickable: AnyObject {}

/// Installs the cursorUpdate tracking area. The view itself must be the owner:
/// AppKit routes cursor updates through the view, not an external object.
enum PointerCursorTracker {
    private static var lastTrace = Date.distantPast

    static func ensureArea(on view: NSView) {
        guard
            !view.trackingAreas.contains(where: { ($0.owner as AnyObject?) === view })
        else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: view,
            userInfo: nil,
        )
        view.addTrackingArea(area)
    }

    static func noteCursorUpdate() {
        guard ProcessInfo.processInfo.environment["UTILITY_CURSOR_TRACE"] == "1",
            Date().timeIntervalSince(lastTrace) > 0.5
        else { return }
        lastTrace = Date()
        debugLog("[Cursor] cursorUpdate fired")
    }
}

/// Button that shows the pointing-hand cursor over its whole bounds.
final class PointerButton: NSButton, PointerClickable {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        PointerCursorTracker.ensureArea(on: self)
    }

    override func cursorUpdate(with _: NSEvent) {
        PointerCursorTracker.noteCursorUpdate()
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHidden, isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Row view for list rows that respond to a single click.
class PointerRowView: NSTableRowView, PointerClickable {
    private var baseTextColors: [ObjectIdentifier: NSColor] = [:]
    private var baseTintColors: [ObjectIdentifier: NSColor] = [:]

    /// Keeps the active selection color when first responder moves to the editor or
    /// terminal right after the click; AppKit would otherwise paint it in gray.
    override func drawSelection(in _: NSRect) {
        guard isSelected else { return }
        let color =
            window?.isKeyWindow == true ? VSTheme.selectionActive : VSTheme.selectionInactive
        color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4,
        ).fill()
    }

    override var isSelected: Bool {
        didSet { applySelectionStyle() }
    }

    override func layout() {
        super.layout()
        applySelectionStyle()
    }

    private func applySelectionStyle() {
        applySelectionStyle(in: self)
    }

    /// Selected rows turn text and icons white; unselected rows restore the base color
    /// recorded while the cell was configured.
    private func applySelectionStyle(in view: NSView) {
        if let label = view as? NSTextField {
            let id = ObjectIdentifier(label)
            if isSelected {
                if let current = label.textColor, current != VSTheme.selectionText {
                    baseTextColors[id] = current
                }
                if label.textColor != VSTheme.selectionText {
                    label.textColor = VSTheme.selectionText
                }
            } else if let base = baseTextColors[id], label.textColor != base {
                label.textColor = base
            }
        }
        if let image = view as? NSImageView {
            let id = ObjectIdentifier(image)
            if isSelected {
                if let current = image.contentTintColor, current != VSTheme.selectionText {
                    baseTintColors[id] = current
                }
                if image.contentTintColor != VSTheme.selectionText {
                    image.contentTintColor = VSTheme.selectionText
                }
            } else if let base = baseTintColors[id], image.contentTintColor != base {
                image.contentTintColor = base
            }
        }
        if let button = view as? NSButton {
            let id = ObjectIdentifier(button)
            if isSelected {
                if let current = button.contentTintColor, current != VSTheme.selectionText {
                    baseTintColors[id] = current
                }
                if button.contentTintColor != VSTheme.selectionText {
                    button.contentTintColor = VSTheme.selectionText
                }
            } else if let base = baseTintColors[id], button.contentTintColor != base {
                button.contentTintColor = base
            }
        }
        for child in view.subviews { applySelectionStyle(in: child) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        PointerCursorTracker.ensureArea(on: self)
    }

    override func cursorUpdate(with _: NSEvent) {
        PointerCursorTracker.noteCursorUpdate()
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
