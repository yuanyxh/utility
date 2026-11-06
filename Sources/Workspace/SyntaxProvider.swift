import Cocoa

/// Supplies syntax definitions and coloured tokens so the editor never depends
/// on the scanner implementation.
@MainActor
protocol SyntaxProvider {
    func definition(for url: URL) -> SyntaxDefinition?
    func tokens(in text: NSString, range: NSRange, definition: SyntaxDefinition) -> [SyntaxToken]
    func color(for kind: SyntaxTokenKind) -> NSColor
}

@MainActor
struct DefaultSyntaxProvider: SyntaxProvider {
    func definition(for url: URL) -> SyntaxDefinition? {
        SyntaxDefinitions.definition(forExtension: url.pathExtension)
    }

    func tokens(in text: NSString, range: NSRange, definition: SyntaxDefinition) -> [SyntaxToken] {
        SyntaxHighlighter.tokens(in: text, range: range, definition: definition)
    }

    func color(for kind: SyntaxTokenKind) -> NSColor {
        SyntaxHighlighter.color(for: kind)
    }
}
