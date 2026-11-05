import Cocoa

enum SyntaxTokenKind: String {
    case keyword
    case string
    case comment
    case number
}

struct SyntaxToken {
    let range: NSRange
    let kind: SyntaxTokenKind
}

/// Scans `range` of `text` and returns coloured ranges. Strings stop at the line
/// end, block comments may span lines. Callers pass a line-aligned range.
enum SyntaxHighlighter {
    static func apply(
        text: NSString, visibleRange: NSRange, definition: SyntaxDefinition,
    ) -> [(NSRange, NSColor)] {
        tokens(in: text, range: visibleRange, definition: definition).map {
            ($0.range, color(for: $0.kind))
        }
    }

    static func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: return VSTheme.syntaxKey
        case .string: return VSTheme.syntaxString
        case .comment: return VSTheme.syntaxComment
        case .number: return VSTheme.syntaxNumber
        }
    }

    static func tokens(
        in text: NSString, range: NSRange, definition: SyntaxDefinition,
    ) -> [SyntaxToken] {
        guard range.length > 0, range.location >= 0,
            range.location + range.length <= text.length
        else { return [] }

        var tokens: [SyntaxToken] = []
        var index = range.location
        let end = range.location + range.length
        var pendingBlockEnd: String?

        while index < end {
            if let terminator = pendingBlockEnd {
                if let close = find(terminator, in: text, from: index, to: end) {
                    let tokenEnd = close + terminator.utf16.count
                    tokens.append(SyntaxToken(range: span(index, tokenEnd), kind: .comment))
                    index = tokenEnd
                    pendingBlockEnd = nil
                } else {
                    tokens.append(SyntaxToken(range: span(index, end), kind: .comment))
                    index = end
                }
                continue
            }

            if let line = definition.lineComment, matches(line, in: text, at: index, limit: end) {
                let lineEnd = lineEndIndex(in: text, from: index, limit: end)
                tokens.append(SyntaxToken(range: span(index, lineEnd), kind: .comment))
                index = lineEnd
                continue
            }

            if let block = definition.blockComment,
                matches(block.start, in: text, at: index, limit: end)
            {
                let contentStart = index + block.start.utf16.count
                if let close = find(block.end, in: text, from: contentStart, to: end) {
                    let tokenEnd = close + block.end.utf16.count
                    tokens.append(SyntaxToken(range: span(index, tokenEnd), kind: .comment))
                    index = tokenEnd
                } else {
                    tokens.append(SyntaxToken(range: span(index, end), kind: .comment))
                    index = end
                    pendingBlockEnd = block.end
                }
                continue
            }

            if let delimiter = delimiter(at: index, in: text, definition: definition, limit: end) {
                let tokenEnd = stringEnd(
                    in: text, from: index + delimiter.utf16.count, delimiter: delimiter, limit: end,
                )
                tokens.append(SyntaxToken(range: span(index, tokenEnd), kind: .string))
                index = tokenEnd
                continue
            }

            let character = text.character(at: index)
            if isDigit(character) {
                let tokenEnd = numberEnd(in: text, from: index, limit: end)
                tokens.append(SyntaxToken(range: span(index, tokenEnd), kind: .number))
                index = tokenEnd
                continue
            }

            if isIdentifierStart(character) {
                var cursor = index + 1
                while cursor < end, isIdentifierBody(text.character(at: cursor)) {
                    cursor += 1
                }
                let word = text.substring(with: NSRange(location: index, length: cursor - index))
                if definition.containsKeyword(word) {
                    tokens.append(SyntaxToken(range: span(index, cursor), kind: .keyword))
                }
                index = cursor
                continue
            }

            index += 1
        }
        return tokens
    }

    private static func span(_ start: Int, _ end: Int) -> NSRange {
        NSRange(location: start, length: end - start)
    }

    private static func matches(
        _ needle: String, in text: NSString, at index: Int, limit: Int,
    ) -> Bool {
        let length = needle.utf16.count
        guard length > 0, index + length <= limit else { return false }
        return text.substring(with: span(index, index + length)) == needle
    }

    private static func find(
        _ needle: String, in text: NSString, from start: Int, to limit: Int,
    ) -> Int? {
        let length = needle.utf16.count
        guard length > 0, start + length <= limit else { return nil }
        var index = start
        while index + length <= limit {
            if matches(needle, in: text, at: index, limit: limit) { return index }
            index += 1
        }
        return nil
    }

    private static func lineEndIndex(in text: NSString, from index: Int, limit: Int) -> Int {
        var cursor = index
        while cursor < limit, text.character(at: cursor) != 10 {
            cursor += 1
        }
        return cursor
    }

    private static func delimiter(
        at index: Int, in text: NSString, definition: SyntaxDefinition, limit: Int,
    ) -> String? {
        for delimiter in definition.stringDelimiters {
            if matches(delimiter, in: text, at: index, limit: limit) { return delimiter }
        }
        return nil
    }

    private static func stringEnd(
        in text: NSString, from start: Int, delimiter: String, limit: Int,
    ) -> Int {
        var cursor = start
        while cursor < limit {
            let character = text.character(at: cursor)
            if character == 92 {
                cursor += 2
                continue
            }
            if matches(delimiter, in: text, at: cursor, limit: limit) {
                return cursor + delimiter.utf16.count
            }
            if character == 10 {
                return cursor
            }
            cursor += 1
        }
        return limit
    }

    private static func numberEnd(in text: NSString, from start: Int, limit: Int) -> Int {
        var cursor = start
        if cursor + 1 < limit, text.character(at: cursor) == 48,
            text.character(at: cursor + 1) == 120 || text.character(at: cursor + 1) == 88
        {
            cursor += 2
            while cursor < limit, isHexDigit(text.character(at: cursor)) {
                cursor += 1
            }
            return cursor
        }
        while cursor < limit, isDigit(text.character(at: cursor)) {
            cursor += 1
        }
        if cursor < limit, text.character(at: cursor) == 46 {
            cursor += 1
            while cursor < limit, isDigit(text.character(at: cursor)) {
                cursor += 1
            }
        }
        if cursor < limit, text.character(at: cursor) == 101 || text.character(at: cursor) == 69 {
            var probe = cursor + 1
            if probe < limit, text.character(at: probe) == 43 || text.character(at: probe) == 45 {
                probe += 1
            }
            let digitsStart = probe
            while probe < limit, isDigit(text.character(at: probe)) {
                probe += 1
            }
            if probe > digitsStart { cursor = probe }
        }
        return cursor
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }

    private static func isHexDigit(_ character: unichar) -> Bool {
        isDigit(character)
            || (character >= 97 && character <= 102)
            || (character >= 65 && character <= 70)
    }

    private static func isIdentifierStart(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
            || character == 95 || character == 36
    }

    private static func isIdentifierBody(_ character: unichar) -> Bool {
        isIdentifierStart(character) || isDigit(character)
    }
}
