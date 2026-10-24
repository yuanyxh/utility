import Foundation

/// Regex fallbacks for import extraction. AST-backed languages use these only
/// when the AST pipeline is unavailable or has failed three times.
enum ImportRegex {
    // MARK: - Languages with identifier specifiers

    static func swift(_ content: String, filePath: String) -> [ImportRecord] {
        let pattern = #"(?m)^[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:class|struct|enum|protocol|func|var|let|typealias)?[ \t]*([A-Za-z_][\w.]*)"#
        return identifierMatches(pattern, in: CommentStringStripper.strip(content), filePath: filePath, confidence: 0.9)
    }

    static func java(_ content: String, filePath: String) -> [ImportRecord] {
        let pattern = #"(?m)^[ \t]*import[ \t]+(?:static[ \t]+)?([\w.]+)"#
        return identifierMatches(pattern, in: CommentStringStripper.strip(content), filePath: filePath, confidence: 0.9)
    }

    static func kotlin(_ content: String, filePath: String) -> [ImportRecord] {
        // `import a.b.C as Alias` — the capture stops at whitespace.
        java(content, filePath: filePath)
    }

    static func python(_ content: String, filePath: String) -> [ImportRecord] {
        let stripped = CommentStringStripper.strip(content)
        var out: [ImportRecord] = []

        let from = #"(?m)^[ \t]*from[ \t]+([.\w]+)[ \t]+import\b"#
        out += identifierMatches(from, in: stripped, filePath: filePath, confidence: 0.6)

        // `import a, b as c` — split the alias list per line.
        let importLine = #"(?m)^[ \t]*import[ \t]+(.+)$"#
        forEachMatch(importLine, in: stripped) { line, range in
            let text = (stripped as NSString).substring(with: range)
            for part in text.split(separator: ",") {
                let name = part.components(separatedBy: " as ").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !name.isEmpty {
                    out.append(ImportRecord(
                        fromPath: filePath, rawTarget: name, kind: .staticImport,
                        line: line, confidence: 0.6,
                    ))
                }
            }
        }
        return dedupe(out)
    }

    // MARK: - JS / TS / Vue (string specifiers)

    static func js(_ content: String, filePath: String) -> [ImportRecord] {
        let stripped = stripComments(content)
        let patterns: [(String, ImportKind)] = [
            (#"(?m)^[ \t]*import\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]"#, .staticImport),
            (#"(?m)^[ \t]*export\s+(?:\*|\{[^}]*\})\s+from\s+['"]([^'"]+)['"]"#, .exportFrom),
            (#"require\(\s*['"]([^'"]+)['"]\s*\)"#, .require),
            (#"import\(\s*['"]([^'"]+)['"]\s*\)"#, .dynamicImport),
        ]
        var out: [ImportRecord] = []
        for (pattern, kind) in patterns {
            forEachMatch(pattern, in: stripped) { line, range in
                let raw = (stripped as NSString).substring(with: range)
                out.append(ImportRecord(
                    fromPath: filePath, rawTarget: raw, kind: kind,
                    line: line, confidence: 0.6,
                ))
            }
        }
        return dedupe(out)
    }

    static func vue(_ content: String, filePath: String) -> [ImportRecord] {
        let pattern = #"(?s)<script\b[^>]*>(.*?)</script>"#
        var out: [ImportRecord] = []
        forEachMatch(pattern, in: content) { _, range in
            let block = (content as NSString).substring(with: range)
            let blockStart = range.location
            let baseLine = lineNumber(in: content, at: blockStart)
            for imp in js(block, filePath: filePath) {
                var copy = imp
                copy.line = (imp.line ?? 1) + baseLine - 1
                out.append(copy)
            }
        }
        return dedupe(out)
    }

    // MARK: - Helpers

    private static func identifierMatches(
        _ pattern: String, in content: String, filePath: String, confidence: Double
    ) -> [ImportRecord] {
        var out: [ImportRecord] = []
        forEachMatch(pattern, in: content) { line, range in
            let raw = (content as NSString).substring(with: range)
            out.append(ImportRecord(
                fromPath: filePath, rawTarget: raw, kind: .staticImport,
                line: line, confidence: confidence,
            ))
        }
        return dedupe(out)
    }

    private static func forEachMatch(
        _ pattern: String, in content: String, _ body: (Int, NSRange) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = content as NSString
        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            body(lineNumber(in: content, at: match.range.location), range)
        }
    }

    private static func lineNumber(in content: String, at location: Int) -> Int {
        let prefix = (content as NSString).substring(to: max(0, location))
        return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static func dedupe(_ imports: [ImportRecord]) -> [ImportRecord] {
        var seen = Set<String>()
        return imports.filter { imp in
            let key = "\(imp.fromPath)\u{0}\(imp.rawTarget)\u{0}\(imp.kind)\u{0}\(imp.line ?? 0)"
            return seen.insert(key).inserted
        }
    }

    /// Remove comments while preserving string literals (JS specifiers live inside quotes).
    private static func stripComments(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        var inBlock = false
        var inLine = false
        var quote: Character?

        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)

            if inBlock {
                if c == "*", next < text.endIndex, text[next] == "/" {
                    inBlock = false
                    i = text.index(after: next)
                } else {
                    if c == "\n" || c == "\r" { result.append(c) }
                    i = next
                }
                continue
            }
            if inLine {
                if c == "\n" { inLine = false; result.append(c) }
                i = next
                continue
            }
            if let q = quote {
                result.append(c)
                if c == "\\", next < text.endIndex {
                    result.append(text[next])
                    i = text.index(after: next)
                    continue
                }
                if c == q { quote = nil }
                i = next
                continue
            }
            if c == "/", next < text.endIndex, text[next] == "/" {
                inLine = true
                i = text.index(after: next)
                continue
            }
            if c == "/", next < text.endIndex, text[next] == "*" {
                inBlock = true
                i = text.index(after: next)
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                quote = c
            }
            result.append(c)
            i = next
        }
        return result
    }
}
