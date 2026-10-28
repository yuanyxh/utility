import Cocoa

/// VS Code dark palette shared by utility windows.
enum VSTheme {
    static let windowBackground = color(0x1E1E1E)
    static let sidebarBackground = color(0x252526)
    static let separator = color(0x3C3C3C)
    static let text = color(0xCCCCCC)
    static let secondaryText = color(0x8C8C8C)
    static let selectionActive = color(0x094771)
    static let selectionInactive = color(0x37373D)
    static let badge = color(0xF14C4C)
    static let success = color(0x89D185)
    static let error = color(0xF48771)

    static let editorText = color(0xD4D4D4)
    static let terminalForeground = color(0xCCCCCC)
    static let terminalCaret = color(0xAFAFAD)
    static let terminalSelection = color(0x264F78)

    static let syntaxComment = color(0x6A9955)
    static let syntaxKey = color(0x9CDCFE)
    static let syntaxString = color(0xCE9178)
    static let syntaxNumber = color(0xB5CEA8)
    static let syntaxPunctuation = color(0xD4D4D4)

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1,
        )
    }
}
