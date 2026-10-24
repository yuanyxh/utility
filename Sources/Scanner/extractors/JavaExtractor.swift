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
        let cleaned = CommentStringStripper.strip(content)
        let lines = cleaned.components(separatedBy: .newlines)

        var symbols: [SymbolRecord] = []
        var tracker = SymbolBodyTracker()
        var lastAnnotation: String?

        for (lineIdx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // ── track annotations ──
            if trimmed.hasPrefix("@") {
                // Capture annotation name (skip value args)
                let parts = trimmed.dropFirst().components(separatedBy: CharacterSet(charactersIn: "("))
                lastAnnotation = parts[0].trimmingCharacters(in: .whitespaces)
                // If this is an inline annotation (on same line as declaration),
                // fall through so the declaration regex below can still match
                guard trimmed.contains(" ") else { continue }
            }

            // ── update brace depth and resolve finished bodies ──
            let depth = tracker.advance(trimmed, lineIdx: lineIdx, symbols: &symbols)
            let prevDepth = depth.prevDepth

            // Extract at file level (0) or inside class body (1)
            guard prevDepth <= 1 else {
                lastAnnotation = nil
                continue
            }

            // ── match type declarations ──
            if let m = Self.typeDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
                let kind = m[3]
                let name = m[4]

                let docComment = lastAnnotation // use last annotation as doc context
                let sig: String? = if kind == "class" || kind == "interface" || kind == "enum" {
                    Self.buildTypeSig(name, rest: m[5])
                } else {
                    nil
                }

                symbols.append(SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: sig,
                    docComment: docComment,
                    visibility: visibility,
                    startLine: lineIdx + 1,
                ))
                tracker.attachSymbol(
                    at: symbols.count - 1, lineIdx: lineIdx, depth: depth,
                    expectsBodyLater: true, symbols: &symbols,
                )

                lastAnnotation = nil
                continue
            }

            // ── match method declarations ──
            if let m = Self.methodDeclRegex.match(trimmed) {
                let visibility = m[1].isEmpty ? nil : m[1]
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
                    visibility: visibility,
                    startLine: lineIdx + 1,
                ))
                tracker.attachSymbol(
                    at: symbols.count - 1, lineIdx: lineIdx, depth: depth,
                    expectsBodyLater: true, symbols: &symbols,
                )

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
                    visibility: visibility,
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

    /// Matches type declarations: [visibility] [modifiers] class/interface/enum/@interface/record Name [...]
    /// Groups: 1=visibility, 2=modifiers, 3=kind, 4=name, 5=rest (extends/implements)
    private static let typeDeclRegex: NSRegularExpression = {
        let raw = #"^\s*(?:(?:@[a-zA-Z_]\w*\s+)*)(public|private|protected)?\s*(static|abstract|final|sealed|non-sealed|default|strictfp)?\s*(class|interface|enum|@interface|record)\s+([a-zA-Z_][a-zA-Z0-9_]*)(.*)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches method declarations: [visibility] [modifiers] returnType name(params) ...
    /// Groups: 1=visibility, 2=modifiers, 3=returnType, 4=name, 5=params
    private static let methodDeclRegex: NSRegularExpression = {
        // Leading annotations (like @Override) are consumed but not captured
        let raw = #"^\s*(?:(?:@[a-zA-Z_]\w*\s+)*)(public|private|protected)?\s*(static|final|abstract|synchronized|native|default|sealed)?\s*"# +
            #"([a-zA-Z_][a-zA-Z0-9_.<>?]+)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)\)"#
        return try! NSRegularExpression(pattern: raw)
    }()

    /// Matches field declarations: [visibility] Type name [= ...];
    /// Groups: 1=visibility, 2=modifiers, 3=type, 4=name
    private static let fieldDeclRegex: NSRegularExpression = {
        // Name starts upper or lower (Java constants like TAG, SOME_VAL)
        let raw = #"^\s*(?:(?:@[a-zA-Z_]\w*\s+)*)(public|private|protected)?\s*(static|final|volatile|transient)?\s*"# +
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
            in: rest, range: NSRange(rest.startIndex..., in: rest),
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

    func imports(from content: String, filePath: String) -> [ImportRecord] {
        ImportRegex.java(content, filePath: filePath)
    }
}
