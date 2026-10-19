import Foundation

/// Swift symbol extractor using regex + brace-depth tracking.
/// Extracts class, struct, enum, protocol, extension, func, var, let, typealias, subscript, init,
/// actor, macro, precedencegroup, operator.
struct SwiftExtractor: SymbolExtractor {
    let language = "swift"
    let supportedExtensions: Set<String> = ["swift"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        let cleaned = CommentStringStripper.strip(content)
        let lines = cleaned.components(separatedBy: .newlines)

        var symbols: [SymbolRecord] = []
        var tracker = SymbolBodyTracker()
        var currentDocComment: String?
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

                let depth = tracker.advanceDepthOnly(trimmed)

                if newParen <= 0 {
                    // function signature complete
                    let sig = combined.trimmingCharacters(in: .whitespaces)
                    if let s = Self.extractFuncSymbol(sig, visibility: pf.visibility,
                                                      docComment: currentDocComment,
                                                      filePath: filePath,
                                                      startLine: pf.startLine)
                    {
                        symbols.append(s)
                        tracker.attachSymbol(
                            at: symbols.count - 1, lineIdx: lineIdx, depth: depth,
                            expectsBodyLater: true, symbols: &symbols,
                        )
                    }
                    pendingFunc = nil
                } else {
                    pendingFunc = (pf.visibility, combined, newParen, pf.startLine)
                }
                continue
            }

            // ── update brace depth and resolve finished bodies ──
            let depth = tracker.advance(trimmed, lineIdx: lineIdx, symbols: &symbols)
            let prevDepth = depth.prevDepth
            let newDepth = depth.newDepth

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

                tracker.attachSymbol(
                    at: symbols.count - 1, lineIdx: lineIdx, depth: depth,
                    expectsBodyLater: Self.kindHasBody(captures.keyword), symbols: &symbols,
                )

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
}
