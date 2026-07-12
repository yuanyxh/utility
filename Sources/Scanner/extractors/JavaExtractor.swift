import Foundation

/// Java symbol extractor using regex + brace-depth tracking.
///
/// Extracts at file level and inside class bodies:
///   - class / interface / enum / @interface declarations
///   - method declarations
///   - field declarations
///   - annotations as decorator context
struct JavaExtractor: SymbolExtractor {
    let language = "java"
    let supportedExtensions: Set<String> = ["java"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        let cleaned = Self.stripCommentsAndStrings(content)
        let lines = cleaned.components(separatedBy: .newlines)

        var symbols: [SymbolRecord] = []
        var braceDepth = 0
        var lastAnnotation: String?

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // ── track annotations ──
            if trimmed.hasPrefix("@") {
                // Capture annotation name (skip value args)
                let parts = trimmed.dropFirst().components(separatedBy: CharacterSet(charactersIn: "("))
                lastAnnotation = parts[0].trimmingCharacters(in: .whitespaces)
                continue
            }

            // ── update brace depth ──
            let openBraces = trimmed.filter { $0 == "{" }.count
            let closeBraces = trimmed.filter { $0 == "}" }.count
            let prevDepth = braceDepth
            braceDepth += openBraces - closeBraces

            // Extract at file level (0) or inside class body (1)
            guard prevDepth <= 1 else {
                lastAnnotation = nil
                continue
            }

            // ── match type declarations ──
            if let m = Self.typeDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
                let modifiers = m[2].isEmpty ? nil : m[2]
                let kind = m[3]
                let name = m[4]

                let docComment = lastAnnotation // use last annotation as doc context
                let sig: String?
                if kind == "class" || kind == "interface" || kind == "enum" {
                    sig = Self.buildTypeSig(name, rest: m[5])
                } else {
                    sig = nil
                }

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: sig,
                    docComment: docComment,
                    visibility: visibility
                ))

                lastAnnotation = nil
                continue
            }

            // ── match method declarations ──
            if let m = Self.methodDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
                let modifiers = m[2]
                let returnType = m[3].trimmingCharacters(in: .whitespaces)
                let name = m[4]
                let params = m[5]

                let sig = "\(name)(\(params.trimmingCharacters(in: .whitespaces)))"
                let fullSig = returnType.isEmpty ? sig : "\(returnType) \(sig)"

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: "method",
                    signature: fullSig,
                    docComment: lastAnnotation,
                    visibility: visibility
                ))

                lastAnnotation = nil
                continue
            }

            // ── match field declarations (at class level) ──
            // Groups: 1=visibility, 2=modifiers, 3=type, 4=name
            if prevDepth == 1, let m = Self.fieldDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
                let type = m[3].trimmingCharacters(in: .whitespaces)
                let name = m[4].trimmingCharacters(in: .whitespaces)

                // Reject false positives matching Java keywords
                guard !Self.javaKeywords.contains(type) && !Self.javaKeywords.contains(name) else {
                    lastAnnotation = nil
                    continue
                }

                let sig = type.isEmpty ? nil : "\(name): \(type)"

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: "field",
                    signature: sig,
                    docComment: lastAnnotation,
                    visibility: visibility
                ))

                lastAnnotation = nil
                continue
            }

            lastAnnotation = nil
        }

        return symbols
    }

    // MARK: - Regex

    /// Matches type declarations: [visibility] [modifiers] class/interface/enum/@interface Name [...]
    /// Groups: 1=visibility, 2=modifiers, 3=kind, 4=name, 5=rest (extends/implements)
    private static let typeDeclRegex: NSRegularExpression = {
        let raw = #"^\s*(public|private|protected)?\s*(static|abstract|final|sealed|non-sealed)?\s*(class|interface|enum|@interface)\s+([a-zA-Z_][a-zA-Z0-9_]*)(.*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches method declarations: [visibility] [modifiers] returnType name(params) ...
    /// Groups: 1=visibility, 2=modifiers, 3=returnType, 4=name, 5=params
    private static let methodDeclRegex: NSRegularExpression = {
        // Type: simple name or qualified (Foo.Bar) or generic (Foo<Bar>)
        let raw = #"^\s*(public|private|protected)?\s*(static|final|abstract|synchronized|native)?\s*"# +
            #"([a-zA-Z_][a-zA-Z0-9_.<>?]+)\s+([a-z][a-zA-Z0-9_]*)\s*\(([^)]*)\)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches field declarations: [visibility] Type name [= ...];
    /// Groups: 1=visibility, 2=modifiers, 3=type, 4=name
    private static let fieldDeclRegex: NSRegularExpression = {
        // Name starts upper or lower (Java constants like TAG, SOME_VAL)
        let raw = #"^\s*(public|private|protected)?\s*(static|final|volatile|transient)?\s*"# +
            #"([a-zA-Z_][a-zA-Z0-9_.<>?]+)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*(?:=|;|$)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Java keywords that cannot be field types or names.
    private static let javaKeywords: Set<String> = [
        "return", "new", "this", "super", "null", "true", "false", "void",
        "if", "for", "while", "switch", "case", "break", "continue",
        "import", "package", "throws", "throw", "class", "enum", "interface",
        "public", "private", "protected", "static", "final", "abstract",
        "synchronized", "native", "volatile", "transient", "strictfp",
        "var", "const", "goto",
    ]

    // MARK: - Helpers

    private static func buildTypeSig(_ name: String, rest: String) -> String {
        var sig = name
        // Extract generic type parameters
        if let m = try? NSRegularExpression(pattern: #"<([^>]*)>"#).firstMatch(
            in: rest, range: NSRange(rest.startIndex..., in: rest)
        ) {
            let range = m.range(at: 1)
            if range.location != NSNotFound {
                let typeParams = (rest as NSString).substring(with: range)
                sig += "<\(typeParams)>"
            }
        }
        // Extract extends
        if let extendsRange = rest.range(of: "extends") {
            let after = rest[extendsRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: CharacterSet.whitespaces).first ?? ""
            if !after.isEmpty {
                sig += " extends \(after)"
            }
        }
        // Extract implements
        if let implementsRange = rest.range(of: "implements") {
            let after = rest[implementsRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: CharacterSet.whitespaces).first ?? ""
            if !after.isEmpty {
                sig += " implements \(after)"
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
                    i = text.index(after: next)
                    continue
                }
                if c == "\"" { inString = false }
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
