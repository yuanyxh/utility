import Foundation

/// Swift symbol extractor using regex + brace-depth tracking.
/// Extracts class, struct, enum, protocol, extension, func, var, let, typealias, subscript, init,
/// actor, macro, precedencegroup, operator.
struct SwiftExtractor: SymbolExtractor {
    let language = "swift"
    let supportedExtensions: Set<String> = ["swift"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        let cleaned = Self.stripCommentsAndStrings(content)
        let lines = cleaned.components(separatedBy: .newlines)

        var symbols: [SymbolRecord] = []
        var braceDepth = 0
        var currentDocComment: String?
        // 待定 end 的带体符号栈:bodyDepth=nil 表示体在后续行打开,等待本行/后续行开 brace 落地
        var bodyStack: [(symIdx: Int, bodyDepth: Int?)] = []
        var pendingFunc: (visibility: String?, signature: String, parenDepth: Int, startLine: Int)?

        for (lineIdx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                pendingFunc = nil
                continue
            }

            // ── collect doc comment ──
            if trimmed.hasPrefix("///") {
                if let existing = currentDocComment {
                    currentDocComment = existing + "\n" + trimmed
                } else {
                    currentDocComment = trimmed
                }
                continue
            }

            // ── handle multi-line function signature ──
            if let pf = pendingFunc {
                let combined = pf.signature + " " + trimmed
                let newParen = pf.parenDepth
                    + trimmed.count(where: { $0 == "(" })
                    - trimmed.count(where: { $0 == ")" })

                let lineOpen = trimmed.count(where: { $0 == "{" })
                let lineClose = trimmed.count(where: { $0 == "}" })
                let prev = braceDepth
                braceDepth += lineOpen - lineClose
                let nextDepth = braceDepth

                if newParen <= 0 {
                    // function signature complete
                    let sig = combined.trimmingCharacters(in: .whitespaces)
                    if let s = Self.extractFuncSymbol(sig, visibility: pf.visibility,
                                                      docComment: currentDocComment,
                                                      filePath: filePath,
                                                      startLine: pf.startLine)
                    {
                        symbols.append(s)
                        let idx = symbols.count - 1
                        if lineOpen > 0 {
                            if nextDepth == prev {
                                symbols[idx].endLine = lineIdx + 1
                            } else {
                                bodyStack.append((symIdx: idx, bodyDepth: nextDepth))
                            }
                        } else {
                            bodyStack.append((symIdx: idx, bodyDepth: nil))
                        }
                    }
                    pendingFunc = nil
                } else {
                    pendingFunc = (pf.visibility, combined, newParen, pf.startLine)
                }
                continue
            }

            // ── update brace depth ──
            let openBraces = trimmed.count(where: { $0 == "{" })
            let closeBraces = trimmed.count(where: { $0 == "}" })
            let prevDepth = braceDepth
            braceDepth += openBraces - closeBraces
            let newDepth = braceDepth

            // ── resolve symbol body end (brace depth fell below body start) ──
            while let top = bodyStack.last {
                if top.bodyDepth == nil {
                    // 等待体在后续行打开:本行开 brace 则落地
                    if openBraces > 0 {
                        if newDepth == prevDepth {
                            symbols[top.symIdx].endLine = lineIdx + 1
                            bodyStack.removeLast()
                        } else {
                            bodyStack[bodyStack.count - 1].bodyDepth = newDepth
                        }
                    }
                    break
                }
                if let bodyDepth = top.bodyDepth, newDepth < bodyDepth {
                    symbols[top.symIdx].endLine = lineIdx + 1
                    bodyStack.removeLast()
                } else {
                    break
                }
            }

            // Only extract at file-level (depth 0) or inside a type (depth 1)
            guard prevDepth <= 1 else {
                if newDepth < prevDepth { currentDocComment = nil }
                continue
            }

            // ── match declarations ──
            if let m = Self.declRegex.match(trimmed) {
                let captures = (visibility: m[1], keyword: m[3], name: m[4])
                let isFunc = captures.keyword == "func"

                // Check if this is a func that continues on next line
                if isFunc {
                    let parenDepth = trimmed.count(where: { $0 == "(" })
                        - trimmed.count(where: { $0 == ")" })
                    if parenDepth > 0 {
                        pendingFunc = (captures.visibility, trimmed, parenDepth, lineIdx + 1)
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
                    visibility: captures.visibility.isEmpty ? nil : captures.visibility,
                    startLine: lineIdx + 1,
                ))

                let idx = symbols.count - 1
                if openBraces > 0 {
                    if newDepth == prevDepth {
                        // 本行开又合(单行体,如 func f() {})
                        symbols[idx].endLine = lineIdx + 1
                    } else {
                        bodyStack.append((symIdx: idx, bodyDepth: newDepth))
                    }
                } else if Self.kindHasBody(captures.keyword) {
                    // 体在后续行打开
                    bodyStack.append((symIdx: idx, bodyDepth: nil))
                } else {
                    // 无体声明(var/let/typealias 等)
                    symbols[idx].endLine = lineIdx + 1
                }

                currentDocComment = nil
            } else if newDepth < prevDepth {
                currentDocComment = nil
            }
        }

        return symbols
    }

    // MARK: - Regex

    private static let declRegex: NSRegularExpression = {
        // Group 2 captures any modifiers (final, @objc, lazy, dynamic, etc.) between visibility and keyword.
        // Greedy * ensures modifiers consume as much as possible, naturally resolving
        // ambiguity like `override class func` vs bare `class` keyword.
        let raw = #"^\s*(open|public|internal|fileprivate|private)?\s*((?:[a-zA-Z_@]\w+\s+)*)(actor|macro|class|struct|enum|protocol|extension|func|var|let|typealias|associatedtype|subscript|init|deinit|precedencegroup|operator)\s+([a-zA-Z_][a-zA-Z0-9_]*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    // MARK: - Helpers

    private static func extractFuncSymbol(_ sigLine: String, visibility: String?,
                                          docComment: String?,
                                          filePath: String,
                                          startLine: Int) -> SymbolRecord?
    {
        guard let m = funcSigRegex.match(sigLine) else { return nil }
        let name = m[4]
        return SymbolRecord(
            filePath: filePath,
            name: name,
            kind: "func",
            signature: Self.trimTrailingBrace(sigLine),
            docComment: docComment,
            visibility: visibility?.isEmpty == false ? visibility : nil,
            startLine: startLine,
        )
    }

    /// Whether a symbol kind has a brace body (so end extends past its start line).
    private static func kindHasBody(_ kind: String) -> Bool {
        switch kind {
        case "class", "struct", "enum", "protocol", "extension", "actor", "macro",
             "func", "subscript", "init", "deinit", "precedencegroup", "operator":
            true
        default:
            false
        }
    }

    /// Matches `func name(...` — the simpler version for already-known func lines.
    private static let funcSigRegex: NSRegularExpression = {
        let raw = #"^\s*(open|public|internal|fileprivate|private)?\s*((?:[a-zA-Z_@]\w+\s+)*)(func)\s+([a-zA-Z_][a-zA-Z0-9_]*)"#
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

        while i < end {
            let c = text[i]
            let next = text.index(after: i)

            if inBlockComment {
                if c == "*", next < end, text[next] == "/" {
                    inBlockComment = false
                    i = text.index(after: next)
                } else {
                    // 保留换行,保证 cleaned 行数与原始一致(行号对齐)
                    if c == "\n" || c == "\r" { result.append(c) }
                    i = next
                }
                continue
            }

            if inLineComment {
                if c == "\n" || c == "\r" { result.append(c) }
                if c == "\n" { inLineComment = false }
                i = next
                continue
            }

            if inString {
                if c == "\\" && next < end {
                    i = text.index(after: next) // skip escaped char
                    continue
                }
                if c == "\"" {
                    inString = false
                } else if c == "\n" || c == "\r" {
                    result.append(c)
                }
                i = next
                continue
            }

            if c == "/", next < end, text[next] == "/" {
                inLineComment = true
                i = text.index(after: next)
                continue
            }

            if c == "/", next < end, text[next] == "*" {
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
