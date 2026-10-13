import Foundation

/// Kotlin symbol extractor using regex + brace-depth tracking.
///
/// Extracts at file level and inside class bodies:
///   - fun / suspend fun — function declarations
///   - class / data class / sealed class / abstract class / enum class
///   - object / companion object
///   - interface
///   - typealias
///   - val / var — top-level and class-level properties
///   - annotations as decorator context
struct KotlinExtractor: SymbolExtractor {
    let language = "kotlin"
    let supportedExtensions: Set<String> = ["kt"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        let cleaned = Self.stripCommentsAndStrings(content)
        let lines = cleaned.components(separatedBy: .newlines)

        var symbols: [SymbolRecord] = []
        var braceDepth = 0
        var lastAnnotation: String?
        // Stack of body-bearing symbols with a pending end: bodyDepth=nil means the body opens on a later line
        var bodyStack: [(symIdx: Int, bodyDepth: Int?)] = []

        for (lineIdx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // ── track annotations ──
            if trimmed.hasPrefix("@") {
                let name = trimmed.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: CharacterSet(charactersIn: "(")).first ?? ""
                lastAnnotation = name
                // Inline annotation: fall through so the declaration regex below can still match
                guard trimmed.contains(" ") else { continue }
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

            // Extract at file level (0) or inside class body (1)
            guard prevDepth <= 1 else {
                lastAnnotation = nil
                continue
            }

            // ── match type / object declarations ──
            if let m = Self.typeDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
                let kind = m[3]
                let name = m[4]
                let rest = m[5]

                let sig: String? = if kind == "class" || kind == "data class" || kind == "sealed class"
                    || kind == "abstract class" || kind == "enum class" || kind == "interface"
                {
                    Self.buildTypeSig(name, rest: rest)
                } else if kind == "object" {
                    name
                } else {
                    nil
                }

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: sig,
                    docComment: lastAnnotation,
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
                } else {
                    bodyStack.append((symIdx: idx, bodyDepth: nil))
                }

                lastAnnotation = nil
                continue
            }

            // ── match companion object ──
            if let m = Self.companionRegex.match(trimmed) {
                let name = m[2].isEmpty ? "companion" : m[2]
                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: "companion object",
                    signature: nil,
                    docComment: lastAnnotation,
                    visibility: m[1].isEmpty ? nil : m[1],
                    startLine: lineIdx + 1,
                ))
                let idx = symbols.count - 1
                if openBraces > 0 {
                    if newDepth == prevDepth {
                        symbols[idx].endLine = lineIdx + 1
                    } else {
                        bodyStack.append((symIdx: idx, bodyDepth: newDepth))
                    }
                } else {
                    bodyStack.append((symIdx: idx, bodyDepth: nil))
                }
                lastAnnotation = nil
                continue
            }

            // ── match function declarations ──
            if let m = Self.funDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
                let modifiers = m[2]
                let name = m[4]
                let params = m[5]

                let sig = "\(name)(\(params.trimmingCharacters(in: .whitespaces)))"

                // Get property-like getter/setter kind
                let isOperator = modifiers.contains("operator")
                let kind = isOperator ? "operator" : "fun"

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: sig,
                    docComment: lastAnnotation,
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
                } else {
                    bodyStack.append((symIdx: idx, bodyDepth: nil))
                }

                lastAnnotation = nil
                continue
            }

            // ── match val / var property declarations ──
            if let m = Self.propertyDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
                let isVal = m[3] == "val"
                let name = m[4]
                let type = m[5].trimmingCharacters(in: .whitespaces)

                let sig = type.isEmpty ? name : "\(name): \(type)"
                let kind = isVal ? "val" : "var"

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: sig,
                    docComment: lastAnnotation,
                    visibility: visibility,
                    startLine: lineIdx + 1,
                    endLine: lineIdx + 1,
                ))

                lastAnnotation = nil
                continue
            }

            // ── match typealias ──
            if let m = Self.typealiasRegex.match(trimmed) {
                let name = m[1]
                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: "typealias",
                    signature: nil,
                    docComment: lastAnnotation,
                    visibility: nil,
                    startLine: lineIdx + 1,
                    endLine: lineIdx + 1,
                ))
                lastAnnotation = nil
                continue
            }

            lastAnnotation = nil
        }

        return symbols
    }

    // MARK: - Regex

    /// Matches type/object declarations: [visibility] [modifiers] (class/data class/sealed class/...) Name
    /// Groups: 1=visibility, 2=modifiers, 3=kind, 4=name, 5=rest
    private static let typeDeclRegex: NSRegularExpression = {
        let raw = #"^\s*(?:(?:@[a-zA-Z_]\w*\s+)*)(public|private|internal|protected)?\s*(open|abstract|final|data|sealed|inner|expect|actual|value|inline|annotation)?\s*"# +
            #"(class|data\s+class|sealed\s+class|abstract\s+class|enum\s+class|interface|fun\s+interface|object|data\s+object|annotation\s+class)\s+"#
            + #"([a-zA-Z_][a-zA-Z0-9_]*)(.*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches companion object: [visibility] companion object [Name]
    /// Groups: 1=visibility, 2=name (optional)
    private static let companionRegex: NSRegularExpression = {
        let raw = #"^\s*(public|private|internal|protected)?\s*companion\s+object(?:\s+([a-zA-Z_][a-zA-Z0-9_]*))?"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches function declarations: [visibility] [modifiers] fun [type.] name(params)
    /// Groups: 1=visibility, 2=modifiers, 3=fun keyword, 4=name, 5=params
    private static let funDeclRegex: NSRegularExpression = {
        // Group 2 greedy * matches any number of modifier tokens (override suspend operator, etc.)
        let raw = #"^\s*(?:(?:@[a-zA-Z_]\w*\s+)*)(public|private|internal|protected)?\s*((?:[a-zA-Z_@]\w+\s+)*)(fun)\s+"#
            + #"(?:[a-zA-Z_][a-zA-Z0-9_.]*\.\s*)?([a-zA-Z_][a-zA-Z0-9_`]*)\s*\(([^)]*)\)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches property declarations: [visibility] [modifiers] val/var name[: type]
    /// Groups: 1=visibility, 2=modifiers, 3=val/var, 4=name, 5=type (optional)
    private static let propertyDeclRegex: NSRegularExpression = {
        // Type allows function types (->), nullable (?), generics (<>,)
        let raw = #"^\s*(?:(?:@[a-zA-Z_]\w*\s+)*)(public|private|internal|protected)?\s*(override|open|abstract|const|lateinit)?\s*(val|var)\s+"#
            + #"([a-zA-Z_][a-zA-Z0-9_]*)\s*(:\s*[^=\n{]+)?"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches typealias: typealias Name = Type
    /// Groups: 1=name
    private static let typealiasRegex: NSRegularExpression = {
        let raw = #"^\s*typealias\s+([a-zA-Z_][a-zA-Z0-9_]*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    // MARK: - Helpers

    private static func buildTypeSig(_ name: String, rest: String) -> String {
        var sig = name
        // Extract generic type parameters
        if let m = try? NSRegularExpression(pattern: #"<([^>]*)>"#).firstMatch(
            in: rest, range: NSRange(rest.startIndex..., in: rest),
        ) {
            let range = m.range(at: 1)
            if range.location != NSNotFound {
                let typeParams = (rest as NSString).substring(with: range)
                sig += "<\(typeParams)>"
            }
        }
        // Extract super type after ':'
        if let colonRange = rest.range(of: " :") ?? rest.range(of: ":") {
            let after = rest[colonRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: CharacterSet.whitespaces).first ?? ""
            if !after.isEmpty {
                sig += " : \(after)"
            }
        }
        return sig
    }

    /// Strip // and /* */ comments and string literals.
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
                    // Preserve newlines so cleaned keeps the same line count as the original (line-number alignment)
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
                    i = text.index(after: next)
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

            if c == "\"" {
                inString = true
                i = next
                continue
            }

            result.append(c)
            i = next
        }

        return result
    }
}
