import Cocoa

// MARK: - ScrollPosition

/// Scroll target position
public enum ScrollPosition {
    case top
    case bottom
}

// MARK: - CursorPosition

/// Cursor target position
public enum CursorPosition {
    case start
    case end
    /// Numeric position (0-based), validity auto-checked on creation
    case index(Int)
}

// MARK: - InputViewStyle

/// Input view style config — gathers all configurable properties, one apply method applies them all
public struct InputViewStyle {
    /// Background color, nil means transparent (drawsBackground = false)
    public var backgroundColor: NSColor?

    /// Font
    public var font: NSFont

    /// Text color
    public var textColor: NSColor

    /// Text inset
    public var textContainerInset: NSSize

    /// Whether editable
    public var isEditable: Bool

    /// Whether to show the vertical scroller
    public var showsVerticalScroller: Bool

    /// Border style, nil means no border
    public var border: BorderStyle?

    public init(
        backgroundColor: NSColor? = nil,
        font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        textColor: NSColor = .labelColor,
        textContainerInset: NSSize = NSSize(width: 8, height: 8),
        isEditable: Bool = true,
        showsVerticalScroller: Bool = false,
        border: BorderStyle? = nil,
    ) {
        self.backgroundColor = backgroundColor
        self.font = font
        self.textColor = textColor
        self.textContainerInset = textContainerInset
        self.isEditable = isEditable
        self.showsVerticalScroller = showsVerticalScroller
        self.border = border
    }

    /// Apply the style to an NSTextView
    func apply(to textView: NSTextView) {
        textView.font = font
        textView.textColor = textColor
        textView.textContainerInset = textContainerInset
        textView.isEditable = isEditable
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]

        if let bg = backgroundColor {
            textView.backgroundColor = bg
            textView.drawsBackground = true
        } else {
            textView.drawsBackground = false
        }
    }
}
