import Cocoa

// MARK: - ScrollPosition

/// 滚动目标位置
public enum ScrollPosition {
    case top
    case bottom
}

// MARK: - CursorPosition

/// 光标目标位置
public enum CursorPosition {
    case start
    case end
    /// 数字位置（0-based），创建时自动校验有效性
    case index(Int)
}

// MARK: - InputViewStyle

/// 输入框样式配置 — 收束所有可配置属性，一个 apply 方法全量应用
public struct InputViewStyle {
    /// 背景色，nil 表示透明（drawsBackground = false）
    public var backgroundColor: NSColor?

    /// 字体
    public var font: NSFont

    /// 文字颜色
    public var textColor: NSColor

    /// 文字内边距
    public var textContainerInset: NSSize

    /// 是否可编辑
    public var isEditable: Bool

    /// 是否显示垂直滚动条
    public var showsVerticalScroller: Bool

    /// 边框样式，nil 表示无边框
    public var border: BorderStyle?

    public init(
        backgroundColor: NSColor? = nil,
        font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        textColor: NSColor = .labelColor,
        textContainerInset: NSSize = NSSize(width: 8, height: 8),
        isEditable: Bool = true,
        showsVerticalScroller: Bool = false,
        border: BorderStyle? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.font = font
        self.textColor = textColor
        self.textContainerInset = textContainerInset
        self.isEditable = isEditable
        self.showsVerticalScroller = showsVerticalScroller
        self.border = border
    }

    /// 将样式应用到 NSTextView
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
