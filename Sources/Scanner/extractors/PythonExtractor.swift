import Foundation

/// Python symbol extractor using regex.
///
/// Extracts:
///   - `def function_name(...)` — at any depth
///   - `class ClassName` — at any depth
///   - `NAME = value` — UPPER_CASE module-level constants
///   - `async def function_name(...)` — at any depth
///   - Decorated definitions (captures `@decorator` as context)
struct PythonExtractor: SymbolExtractor {
    let language = "python"
    let supportedExtensions: Set<String> = ["py"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        let lines = content.components(separatedBy: .newlines)
        var symbols: [SymbolRecord] = []
        var lastDecorator: String?
        var inTripleString = false
        var tripleChar = "\"\"\""
        // 缩进栈定 def/class 体结束:end = 缩进回落到声明缩进那行的上一行
        var openDefs: [(symIdx: Int, indent: Int)] = []
        var lastContentLine = 0

        for (lineIdx, rawLine) in lines.enumerated() {
            // stripped: whitespace-trimmed for content inspection
            let stripped = rawLine.trimmingCharacters(in: .whitespaces)

            // ── skip triple-quoted strings (docstrings / multi-line strings) ──
            if inTripleString {
                if stripped.contains(tripleChar) { inTripleString = false }
                continue
            }
            if let tripleMatch = Self.matchTripleQuote(stripped) {
                if !tripleMatch.closed {
                    inTripleString = true
                    tripleChar = tripleMatch.quote
                    continue
                }
            }

            // ── skip comment-only lines ──
            let noComment = Self.stripInlineComment(stripped)
            guard let beforeComment = noComment, !beforeComment.isEmpty else {
                continue
            }

            // ── resolve def/class body end (indent fell back to ≤ declaration indent) ──
            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            while let top = openDefs.last, indent <= top.indent {
                symbols[top.symIdx].endLine = lastContentLine + 1
                openDefs.removeLast()
            }
            lastContentLine = lineIdx

            // ── decorator tracking ──
            if beforeComment.hasPrefix("@") {
                lastDecorator = beforeComment
                continue
            }

            // ── match def / class ──
            let nsRange = NSRange(beforeComment.startIndex..., in: beforeComment)
            if let match = Self.declRegex.firstMatch(in: beforeComment, range: nsRange) {
                let kind = (beforeComment as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let name = (beforeComment as NSString).substring(with: match.range(at: 2))

                let docComment: String? = if let d = lastDecorator {
                    // Find the docstring immediately after this def for real doc comments
                    // For now just store the decorator as context
                    d
                } else {
                    nil
                }

                let sig: String? = if kind == "def" || kind == "cdef" || kind == "async def" {
                    Self.trimTrailingColon(beforeComment)
                } else {
                    nil
                }

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: sig,
                    docComment: docComment,
                    visibility: nil,
                    startLine: lineIdx + 1,
                ))
                openDefs.append((symIdx: symbols.count - 1, indent: indent))

                lastDecorator = nil
                continue
            }

            // ── match module-level constants (UPPER_CASE) ──
            if Self.isModuleLevel(rawLine),
               let match = Self.constRegex.firstMatch(in: beforeComment, range: nsRange)
            {
                let name = (beforeComment as NSString).substring(with: match.range(at: 1))
                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: "const",
                    signature: nil,
                    docComment: nil,
                    visibility: nil,
                    startLine: lineIdx + 1,
                    endLine: lineIdx + 1,
                ))
                lastDecorator = nil
                continue
            }

            lastDecorator = nil
        }

        // ── EOF:任何未闭合的 def/class 体结束于文件末行 ──
        while let top = openDefs.last {
            symbols[top.symIdx].endLine = lines.count
            openDefs.removeLast()
        }

        return symbols
    }

    // MARK: - Regex

    /// Matches def / class / async def / cdef declarations.
    /// Group 1: kind (def, class, async, cdef)
    /// Group 2: name
    private static let declRegex: NSRegularExpression = {
        // Handles: def, async def, class, cdef (Cython)
        let raw = #"^\s*((?:async\s+)?def|cdef|class)\s+([a-zA-Z_][a-zA-Z0-9_]*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches UPPER_CASE module-level constants: NAME = ...
    private static let constRegex: NSRegularExpression = {
        let raw = #"^\s*([A-Z][A-Z0-9_]*)\s*="#
        return try! NSRegularExpression(pattern: raw)
    }()

    // MARK: - Helpers

    /// Check if a line is at module level (no leading whitespace or minimal indentation).
    private static func isModuleLevel(_ line: String) -> Bool {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        return indent.count == 0
    }

    /// Strip inline `#` comments from a line, respecting strings and triple-quoted strings.
    /// Returns nil if the line is entirely a comment AFTER stripping strings.
    private static func stripInlineComment(_ line: String) -> String? {
        var result = ""
        var i = line.startIndex
        let end = line.endIndex
        var inString = false
        var quoteChar: Character = "\""

        while i < end {
            let c = line[i]
            let remaining = line[i...]

            if inString {
                // Handle triple-quote closing
                if remaining.hasPrefix("\"\"\"") || remaining.hasPrefix("'''") {
                    let tri = String(remaining.prefix(3))
                    if tri.allSatisfy({ $0 == quoteChar }) {
                        i = line.index(i, offsetBy: 3)
                        inString = false
                        continue
                    }
                }
                if c == "\\" {
                    let ni = line.index(after: i)
                    if ni < end {
                        i = line.index(after: ni)
                        continue
                    }
                }
                if c == quoteChar {
                    inString = false
                }
                i = line.index(after: i)
                continue
            }

            // Handle triple-quote opening (either """ or ''')
            if remaining.hasPrefix("\"\"\"") || remaining.hasPrefix("'''") {
                inString = true
                quoteChar = c
                i = line.index(i, offsetBy: 3)
                continue
            }

            if c == "\"" || c == "'" {
                inString = true
                quoteChar = c
                i = line.index(after: i)
                continue
            }

            if c == "#" {
                break
            }

            result.append(c)
            i = line.index(after: i)
        }

        let cleaned = result.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func trimTrailingColon(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespaces)
        if r.hasSuffix(":") { r = String(r.dropLast()) }
        return r.trimmingCharacters(in: .whitespaces)
    }

    /// Detect triple-quoted strings on a line — anywhere in the line, not just at prefix.
    private struct TripleResult { let quote: String; let closed: Bool }

    private static func matchTripleQuote(_ line: String) -> TripleResult? {
        // Check for """ or ''' anywhere in the line
        guard let tripleRange = line.range(of: #"""""""#) ?? line.range(of: "'''") else {
            return nil
        }
        let quote = line[tripleRange]
        let before = line[..<tripleRange.lowerBound]
        let after = line[tripleRange.upperBound...]

        // Count odd/even quotes before the triple — odd means we're inside a string
        let precedingQuotes = before.count(where: { $0 == quote.first })
        if precedingQuotes % 2 == 1 {
            return nil // inside a regular string, not a triple-quote start
        }

        if after.contains(quote) {
            return TripleResult(quote: String(quote), closed: true)
        }
        return TripleResult(quote: String(quote), closed: false)
    }
}
