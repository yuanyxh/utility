import Foundation

enum YAMLTokenKind {
    case comment, key, string, scalar, punctuation
}

struct YAMLToken {
    let range: NSRange
    let kind: YAMLTokenKind
}

/// Lightweight line-oriented YAML tokenizer for the config editor.
/// Visual aid only — block scalars and anchors are not interpreted.
enum YAMLSyntax {
    private static let keyRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:-[ \t]+)?([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*:"#,
    )
    private static let stringRegex = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#,
    )
    private static let scalarRegex = try! NSRegularExpression(
        pattern: #"(?<![\w.-])(?:-?\d+(?:\.\d+)?|true|false|null|yes|no|on|off)(?![\w.-])"#,
        options: [.caseInsensitive],
    )
    private static let markerRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(-)(?=[ \t])|^(---|\.\.\.)$"#,
    )

    static func tokens(in text: String) -> [YAMLToken] {
        let source = text as NSString
        var tokens: [YAMLToken] = []
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            tokens.append(contentsOf: lineTokens(in: source, lineRange: lineRange))
            location = NSMaxRange(lineRange)
        }
        return tokens
    }

    // MARK: - Line tokens

    private static func lineTokens(in source: NSString, lineRange: NSRange) -> [YAMLToken] {
        let contentRange = trimmedLineRange(in: source, lineRange: lineRange)
        guard contentRange.length > 0 else { return [] }

        let line = source.substring(with: contentRange) as NSString
        let strings = stringRanges(in: line)
        let commentStart = commentIndex(in: line, strings: strings)
        let codeLength = commentStart ?? line.length
        let code = line.substring(to: codeLength) as NSString

        let keyTokens = keyTokens(in: code, offset: contentRange.location)
        let keyRanges = keyTokens.map {
            NSRange(location: $0.range.location - contentRange.location, length: $0.range.length)
        }
        var tokens: [YAMLToken] = markerTokens(in: code, offset: contentRange.location)
        tokens.append(contentsOf: keyTokens)
        tokens.append(contentsOf: stringTokens(strings, offset: contentRange.location))
        tokens.append(contentsOf: scalarTokens(
            in: code, excluded: strings + keyRanges, offset: contentRange.location,
        ))
        if let commentStart {
            tokens.append(YAMLToken(
                range: NSRange(
                    location: contentRange.location + commentStart,
                    length: line.length - commentStart,
                ),
                kind: .comment,
            ))
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    /// Strips trailing newline so `$` anchors see one line.
    private static func trimmedLineRange(in source: NSString, lineRange: NSRange) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let char = source.character(at: end - 1)
            guard char == 0x0A || char == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private static func stringRanges(in line: NSString) -> [NSRange] {
        stringRegex.matches(
            in: line as String, range: NSRange(location: 0, length: line.length),
        ).map(\.range)
    }

    /// Inline comment: whitespace before `#`, not inside quotes.
    private static func commentIndex(in line: NSString, strings: [NSRange]) -> Int? {
        var index = 0
        while index < line.length {
            if line.character(at: index) == 0x23 {
                let insideString = strings.contains { NSLocationInRange(index, $0) }
                let precededBySpace = index == 0
                    || line.character(at: index - 1) == 0x20
                    || line.character(at: index - 1) == 0x09
                if !insideString, precededBySpace { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Token producers

    private static func markerTokens(in code: NSString, offset: Int) -> [YAMLToken] {
        guard let match = markerRegex.firstMatch(
            in: code as String, range: NSRange(location: 0, length: code.length),
        ) else { return [] }
        let group = match.range(at: 1).location != NSNotFound ? 1 : 2
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return [] }
        return [YAMLToken(
            range: NSRange(location: offset + range.location, length: range.length),
            kind: .punctuation,
        )]
    }

    private static func keyTokens(in code: NSString, offset: Int) -> [YAMLToken] {
        guard let match = keyRegex.firstMatch(
            in: code as String, range: NSRange(location: 0, length: code.length),
        ) else { return [] }
        let range = match.range(at: 1)
        return [YAMLToken(
            range: NSRange(location: offset + range.location, length: range.length),
            kind: .key,
        )]
    }

    private static func stringTokens(_ ranges: [NSRange], offset: Int) -> [YAMLToken] {
        ranges.map { YAMLToken(
            range: NSRange(location: offset + $0.location, length: $0.length),
            kind: .string,
        ) }
    }

    private static func scalarTokens(
        in code: NSString, excluded: [NSRange], offset: Int,
    ) -> [YAMLToken] {
        scalarRegex.matches(
            in: code as String, range: NSRange(location: 0, length: code.length),
        ).compactMap { match in
            let range = match.range
            guard !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 })
            else { return nil }
            return YAMLToken(
                range: NSRange(location: offset + range.location, length: range.length),
                kind: .scalar,
            )
        }
    }
}
