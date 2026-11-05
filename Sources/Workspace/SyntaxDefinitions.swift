import Foundation

/// Token rules for one file extension. Numbers use a single built-in rule, so they
/// are not configurable per language.
struct SyntaxDefinition {
    let keywords: Set<String>
    let caseInsensitive: Bool
    let lineComment: String?
    let blockComment: (start: String, end: String)?
    let stringDelimiters: [String]

    func containsKeyword(_ word: String) -> Bool {
        caseInsensitive ? keywords.contains(word.lowercased()) : keywords.contains(word)
    }
}

enum SyntaxDefinitions {
    static func definition(forExtension ext: String) -> SyntaxDefinition? {
        switch ext.lowercased() {
        case "swift": return swift
        case "js", "mjs", "cjs": return javascript
        case "ts", "mts", "cts", "jsx", "tsx": return typescript
        case "json", "jsonc": return json
        case "yaml", "yml": return yaml
        case "md", "markdown": return markdown
        case "sh", "bash", "zsh": return shell
        case "py": return python
        case "html", "htm": return html
        case "css": return css
        default: return nil
        }
    }

    private static let swift = SyntaxDefinition(
        keywords: keywords(
            """
            if else guard let var func return for while switch case default break continue
            import class struct enum protocol extension init deinit self Self super nil true false
            try catch throw throws async await some any where in is as static public private
            fileprivate internal open final lazy weak unowned defer repeat do
            """,
        ),
        caseInsensitive: false,
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"\"\"", "\""],
    )

    private static let javascript = SyntaxDefinition(
        keywords: keywords(
            """
            const let var function return if else for while do switch case default break continue
            new class extends super this typeof instanceof in of try catch finally throw async await
            yield import export from default null true false undefined
            """,
        ),
        caseInsensitive: false,
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["`", "\"", "'"],
    )

    private static let typescript = SyntaxDefinition(
        keywords: keywords(
            """
            const let var function return if else for while do switch case default break continue
            new class extends super this typeof instanceof in of try catch finally throw async await
            yield import export from default null true false undefined
            interface type enum implements private public protected readonly static get set
            namespace declare abstract keyof infer satisfies
            """,
        ),
        caseInsensitive: false,
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["`", "\"", "'"],
    )

    private static let json = SyntaxDefinition(
        keywords: keywords("true false null"),
        caseInsensitive: false,
        lineComment: "//",
        blockComment: nil,
        stringDelimiters: ["\""],
    )

    private static let yaml = SyntaxDefinition(
        keywords: keywords("true false null yes no on off"),
        caseInsensitive: true,
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
    )

    private static let markdown = SyntaxDefinition(
        keywords: [],
        caseInsensitive: false,
        lineComment: nil,
        blockComment: nil,
        stringDelimiters: ["`"],
    )

    private static let shell = SyntaxDefinition(
        keywords: keywords(
            """
            if then else elif fi for while until do done case esac function in return export
            local readonly declare echo cd exit set unset shift source
            """,
        ),
        caseInsensitive: false,
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
    )

    private static let python = SyntaxDefinition(
        keywords: keywords(
            """
            def class return if elif else for while import from as pass break continue try except
            finally raise with lambda yield global nonlocal assert del in is not and or None True
            False async await self
            """,
        ),
        caseInsensitive: false,
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"\"\"", "'''", "\"", "'"],
    )

    private static let html = SyntaxDefinition(
        keywords: [],
        caseInsensitive: false,
        lineComment: nil,
        blockComment: ("<!--", "-->"),
        stringDelimiters: ["\"", "'"],
    )

    private static let css = SyntaxDefinition(
        keywords: [],
        caseInsensitive: false,
        lineComment: nil,
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
    )

    private static func keywords(_ text: String, caseInsensitive: Bool = false) -> Set<String> {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        if caseInsensitive {
            return Set(words.map { String($0).lowercased() })
        }
        return Set(words.map(String.init))
    }
}
