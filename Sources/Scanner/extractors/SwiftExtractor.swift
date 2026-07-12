import Foundation

/// Swift symbol extractor using regex + brace-depth tracking.
/// Extracts class, struct, enum, protocol, extension, func, var, let, typealias, subscript, init.
struct SwiftExtractor: SymbolExtractor {
    let language = "swift"
    let supportedExtensions: Set<String> = ["swift"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        let cleaned = Self.stripCommentsAndStrings(content)
        let lines = cleaned.components(separatedBy: .newlines)

        var symbols: [SymbolRecord] = []
        var braceDepth = 0
        var currentDocComment: String?
        var pendingFunc: (visibility: String?, signature: String, parenDepth: Int)?

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                pendingFunc = nil
                continue
            }

            // ── collect doc comment ──
            if trimmed.hasPrefix("///") {
                currentDocComment = trimmed
                continue
            }

            // ── handle multi-line function signature ──
            if let pf = pendingFunc {
                let combined = pf.signature + " " + trimmed
                let newParen = pf.parenDepth
                    + trimmed.filter { $0 == "(" }.count
                    - trimmed.filter { $0 == ")" }.count

                if newParen <= 0 {
                    // function signature complete
                    let sig = combined.trimmingCharacters(in: .whitespaces)
                    if let s = Self.extractFuncSymbol(sig, visibility: pf.visibility,
                                                      docComment: currentDocComment,
                                                      filePath: filePath)
                    {
                        symbols.append(s)
                    }
                    pendingFunc = nil
                } else {
                    pendingFunc = (pf.visibility, combined, newParen)
                }

                // Update brace depth for this line but skip declaration matching
                braceDepth += trimmed.filter { $0 == "{" }.count
                braceDepth -= trimmed.filter { $0 == "}" }.count
                continue
            }

            // ── update brace depth ──
            let openBraces = trimmed.filter { $0 == "{" }.count
            let closeBraces = trimmed.filter { $0 == "}" }.count
            let prevDepth = braceDepth
            braceDepth += openBraces - closeBraces

            // Only extract at file-level (depth 0) or inside a type (depth 1)
            guard prevDepth <= 1 else {
                if braceDepth < prevDepth { currentDocComment = nil }
                continue
            }

            // ── match declarations ──
            if let m = Self.declRegex.match(trimmed) {
                let captures = (visibility: m[1], keyword: m[3], name: m[4])
                let isFunc = captures.keyword == "func"

                // Check if this is a func that continues on next line
                if isFunc {
                    let parenDepth = trimmed.filter { $0 == "(" }.count
                        - trimmed.filter { $0 == ")" }.count
                    if parenDepth > 0 {
                        pendingFunc = (captures.visibility, trimmed, parenDepth)
                        continue
                    }
                }

                // Build signature
                var sig: String? = nil
                if isFunc || captures.keyword == "subscript" || captures.keyword == "init" {
                    sig = Self.trimTrailingBrace(trimmed)
                }

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: captures.name,
                    kind: captures.keyword,
                    signature: sig,
                    docComment: currentDocComment,
                    visibility: captures.visibility.isEmpty ? nil : captures.visibility
                ))

                currentDocComment = nil
            } else if braceDepth < prevDepth {
                currentDocComment = nil
            }
        }

        return symbols
    }

    // MARK: - Regex

    private static let declRegex: NSRegularExpression = {
        let raw = #"^\s*(open|public|internal|fileprivate|private)?\s*(static|class|mutating|nonmutating|override|required|convenience|indirect)?\s*(func|var|let|class|struct|enum|protocol|extension|typealias|associatedtype|subscript|init|deinit)\s+([a-zA-Z_][a-zA-Z0-9_]*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    // MARK: - Helpers

    private static func extractFuncSymbol(_ sigLine: String, visibility: String?,
                                          docComment: String?,
                                          filePath: String) -> SymbolRecord?
    {
        guard let m = funcSigRegex.match(sigLine) else { return nil }
        let name = m[4]
        return SymbolRecord(
            filePath: filePath,
            name: name,
            kind: "func",
            signature: Self.trimTrailingBrace(sigLine),
            docComment: docComment,
            visibility: visibility?.isEmpty == false ? visibility : nil
        )
    }

    /// Matches `func name(...` — the simpler version for already-known func lines.
    private static let funcSigRegex: NSRegularExpression = {
        let raw = #"^\s*(open|public|internal|fileprivate|private)?\s*(static|class|mutating|nonmutating|override|required|convenience)?\s*(func)\s+([a-zA-Z_][a-zA-Z0-9_]*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Remove trailing `{` and whitespace from a signature line.
    private static func trimTrailingBrace(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespaces)
        while result.hasSuffix("{") || result.hasSuffix(" ") {
            result = result.trimmingCharacters(in: .whitespaces)
            if result.hasSuffix("{") { result = String(result.dropLast()) }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Strip // and /* */ comments and string literals for brace-depth tracking.
    private static func stripCommentsAndStrings(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        let end = text.endIndex

        var inBlockComment = false
        var inLineComment = false
        var inString = false
        var inRawString = false

        while i < end {
            let c = text[i]
            let next = text.index(after: i)

            if inBlockComment {
                if c == "*" && next < end && text[next] == "/" {
                    inBlockComment = false
                    i = text.index(after: next)
                } else {
                    i = next
                }
                continue
            }

            if inLineComment {
                if c == "\n" {
                    inLineComment = false
                    result.append(c)
                }
                i = next
                continue
            }

            if inString {
                if c == "\\" && next < end {
                    i = text.index(after: next) // skip escaped char
                    continue
                }
                if c == "\"" || (inRawString && c == "\"") {
                    inString = false
                    inRawString = false
                }
                i = next
                continue
            }

            if c == "/" && next < end && text[next] == "/" {
                inLineComment = true
                i = text.index(after: next)
                continue
            }

            if c == "/" && next < end && text[next] == "*" {
                inBlockComment = true
                i = text.index(after: next)
                continue
            }

            // String literal start
            if c == "\"" {
                inString = true
                i = next
                continue
            }

            // Regular character — preserve for analysis
            result.append(c)
            i = next
        }

        return result
    }
}
