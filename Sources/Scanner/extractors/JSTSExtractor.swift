import Foundation

/// JS/TS symbol extractor using regex.
///
/// Extracts at module level (depth 0):
///   - `export function/class/const/let/var/interface/type name`
///   - `export async function name`
///   - `export default {function,class} name`
///   - `function/class/const/let/var/interface/type name` (no export)
///   - `async function name`
struct JSTSExtractor: SymbolExtractor {
    let language = "typescript"
    let supportedExtensions: Set<String> = ["js", "ts", "jsx", "tsx", "mjs", "cjs"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        let lines = content.components(separatedBy: .newlines)
        var symbols: [SymbolRecord] = []
        var braceDepth = 0
        var currentDocComment: String?
        // Stack of body-bearing symbols with a pending end: bodyDepth=nil means the body opens on a later line
        var bodyStack: [(symIdx: Int, bodyDepth: Int?)] = []

        for (lineIdx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // ── collect doc comment ──
            if trimmed.hasPrefix("/**") || trimmed.hasPrefix("* ") || trimmed == "*/" {
                if currentDocComment == nil {
                    currentDocComment = trimmed
                } else {
                    currentDocComment = currentDocComment! + "\n" + trimmed
                }
                // End of block comment → keep the accumulated text
                if trimmed == "*/" || trimmed.hasSuffix("*/") {
                    // Keep captured
                }
                continue
            }

            // ── strip strings for brace-depth tracking ──
            let stripped = Self.stripStrings(trimmed)
            let openBraces = stripped.count(where: { $0 == "{" })
            let closeBraces = stripped.count(where: { $0 == "}" })
            let prevDepth = braceDepth
            braceDepth += openBraces - closeBraces
            let newDepth = braceDepth

            // ── resolve symbol body end (brace depth fell below body start) ──
            while let top = bodyStack.last {
                if top.bodyDepth == nil {
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

            // Only extract at module level (depth 0)
            guard prevDepth == 0 else {
                if newDepth < prevDepth { currentDocComment = nil }
                continue
            }

            // ── match declarations ──
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = Self.declRegex.firstMatch(in: trimmed, range: nsRange) {
                let exportStr = match.range(at: 1).location != NSNotFound
                    ? (trimmed as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces) : ""
                let kind = (trimmed as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let name = (trimmed as NSString).substring(with: match.range(at: 3))

                let visibility = exportStr == "export" ? "export" : nil
                let sig: String? = kind.hasPrefix("function") ? Self.trimTrailingBrace(trimmed) : nil

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: sig,
                    docComment: currentDocComment,
                    visibility: visibility,
                    startLine: lineIdx + 1,
                ))
                let idx = symbols.count - 1
                if openBraces > 0 {
                    if newDepth == prevDepth {
                        symbols[idx].endLine = lineIdx + 1
                    } else {
                        bodyStack.append((symIdx: idx, bodyDepth: newDepth))
                    }
                } else if Self.kindHasBody(kind) {
                    bodyStack.append((symIdx: idx, bodyDepth: nil))
                } else {
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

    /// Matches module-level declarations:
    ///   (export\s+)?(default\s+)?(async\s+)?(function\*?|class|const|let|var|interface|type)\s+(name)
    private static let declRegex: NSRegularExpression = {
        // Groups: 1=export, 2=kind (with optional prefixes), 3=name
        // We use a non-capturing group for (default|async) since they're part of the kind context
        let raw = #"^\s*(export\s+)?(?:(?:default|async)\s+)*(function\*?|class|const|let|var|interface|type)\s+([a-zA-Z_$][a-zA-Z0-9_$]*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    // MARK: - Helpers

    /// Strip string literals (", ', `) for accurate brace counting.
    private static func stripStrings(_ line: String) -> String {
        var result = ""
        var i = line.startIndex
        let end = line.endIndex
        var inString = false
        var quoteChar: Character = "\""

        while i < end {
            let c = line[i]
            let next = line.index(after: i)

            if inString {
                if c == "\\", next < end {
                    i = line.index(after: next)
                    continue
                }
                if c == quoteChar { inString = false }
                i = next
                continue
            }

            if c == "\"" || c == "'" || c == "`" {
                inString = true
                quoteChar = c
                i = next
                continue
            }

            // Strip // rest of line so braces inside stringified code don't count
            if c == "/", next < end, line[next] == "/" { break }

            result.append(c)
            i = next
        }

        return result
    }

    /// Whether a declaration kind has a brace body (so end extends past its start line).
    /// kind may carry async/default prefixes, so match by suffix.
    private static func kindHasBody(_ kind: String) -> Bool {
        kind.hasSuffix("function") || kind.hasSuffix("class")
            || kind.hasSuffix("interface") || kind.hasSuffix("type")
    }

    private static func trimTrailingBrace(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespaces)
        while r.hasSuffix("{") || r.hasSuffix(" ") {
            r = r.trimmingCharacters(in: .whitespaces)
            if r.hasSuffix("{") { r = String(r.dropLast()) }
        }
        return r.trimmingCharacters(in: .whitespaces)
    }
}
