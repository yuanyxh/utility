import Foundation

/// Lightweight i18n — the catalog is generated from `Sources/Resources/<lang>.json`.
///
/// `L10nKeys.swift` (also generated) exposes the typed accessors; this file only owns
/// loading, language resolution, per-key fallback, and named-placeholder rendering.
enum L10n {
    /// Fallback for any key missing in the current language.
    static let baselineLanguage = "zh-Hans"

    static let languageDidChange = Notification.Name("L10n.languageDidChange")

    /// A placeholder value. The generated accessors choose the case, so a template/value
    /// type mismatch is a compile error.
    enum Arg {
        case string(String)
        case int(Int)
        case double(Double)
    }

    private(set) static var currentLanguage = baselineLanguage
    private static var current: [String: String] = [:]
    private static var baseline: [String: String] = [:]
    private static var loggedKeys: Set<String> = []

    /// Auto-load on first access to any string (system preferred language).
    private static let _ready: Bool = {
        load(language: resolvedLanguage(), notify: false)
        return true
    }()

    /// Called after ConfigManager.load() — overrides the language per config file.
    static func setup() {
        load(
            language: resolvedLanguage(
                configured: ConfigManager.shared.config.general.language,
            ),
            notify: true,
        )
    }

    // MARK: - Language Resolution (Single Source)

    /// Exact match → the baseline's language family (`zh-*` → `zh-Hans`) → English → baseline.
    /// This keeps the historical behaviour where an unsupported system language gets English.
    static func normalize(_ language: String) -> String {
        let raw = language.replacingOccurrences(of: "_", with: "-").lowercased()
        guard !raw.isEmpty else { return baselineLanguage }
        if let exact = availableLanguages.first(where: { $0.lowercased() == raw }) {
            return exact
        }
        let family = raw.split(separator: "-").first.map(String.init) ?? raw
        let baselineFamily = baselineLanguage
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init)
        if family == baselineFamily, availableLanguages.contains(baselineLanguage) {
            return baselineLanguage
        }
        if let english = availableLanguages.first(where: { $0.lowercased() == "en" }) {
            return english
        }
        return baselineLanguage
    }

    /// Currently effective language: config takes priority; empty follows the system preference.
    ///
    /// This is the **single cross-language source of truth** — L10n itself, and the `UTILITY_LANG`
    /// injected into Python both go through here. The default parameter does not read
    /// `ConfigManager`: `_ready` may fire before config load, and reading config then would crash.
    static func resolvedLanguage(configured: String = "") -> String {
        normalize(configured.isEmpty ? preferredLanguage() : configured)
    }

    private static func preferredLanguage() -> String {
        Locale.preferredLanguages.first ?? baselineLanguage
    }

    private static func load(language: String, notify: Bool) {
        let lang = normalize(language)
        baseline = loadJSON(baselineLanguage) ?? [:]
        if lang == baselineLanguage {
            current = baseline
            currentLanguage = lang
        } else if let data = loadJSON(lang) {
            current = data
            currentLanguage = lang
        } else {
            current = baseline
            currentLanguage = baselineLanguage
        }
        loggedKeys.removeAll()
        if notify {
            NotificationCenter.default.post(name: languageDidChange, object: nil)
        }
    }

    private static func loadJSON(_ language: String) -> [String: String]? {
        guard let url = Bundle.module.url(forResource: language, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            debugLog("[L10n] cannot read \(language).json from the resource bundle")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            debugLog("[L10n] \(language).json is not a flat string dictionary")
            return nil
        }
        return json
    }

    // MARK: - Lookup

    static func string(_ key: String) -> String {
        _ = _ready
        return lookup(key)
    }

    static func render(_ key: String, _ args: [String: Arg]) -> String {
        _ = _ready
        return renderTemplate(lookup(key), args: args, key: key)
    }

    /// Current language → baseline → the key itself. A missing baseline key means a broken
    /// install, logged once per key rather than silently rendered as `ns.key`.
    private static func lookup(_ key: String) -> String {
        if let value = current[key] {
            return value
        }
        if let value = baseline[key] {
            if currentLanguage != baselineLanguage, loggedKeys.insert(key).inserted {
                debugLog("[L10n] \(key): no \(currentLanguage) text, falling back to \(baselineLanguage)")
            }
            return value
        }
        if loggedKeys.insert(key).inserted {
            debugLog("[L10n] missing key in every language: \(key)")
        }
        return key
    }

    // MARK: - Named Placeholders

    /// `{name}` (String), `{name:d}` (Int), `{name:.Nf}` (Double). One pass; substituted text is
    /// never rescanned, so a value containing `{other}` is not expanded again.
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)(?::(\.\d+f|d))?\}"#,
    )

    private static func renderTemplate(
        _ template: String,
        args: [String: Arg],
        key: String,
    ) -> String {
        let text = template as NSString
        let matches = placeholderRegex.matches(
            in: template,
            range: NSRange(location: 0, length: text.length),
        )
        guard !matches.isEmpty else { return template }
        var out = ""
        var cursor = 0
        for match in matches {
            out += text.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor),
            )
            let name = text.substring(with: match.range(at: 1))
            let specRange = match.range(at: 2)
            let spec = specRange.location == NSNotFound ? nil : text.substring(with: specRange)
            if let rendered = renderArg(args[name], spec: spec) {
                out += rendered
            } else {
                out += text.substring(with: match.range)
                debugLog("[L10n] \(key): no usable value for placeholder {\(name)}")
            }
            cursor = match.range.location + match.range.length
        }
        out += text.substring(from: cursor)
        return out
    }

    private static func renderArg(_ arg: Arg?, spec: String?) -> String? {
        switch (arg, spec) {
        case let (.string(value), nil):
            value
        case let (.int(value), "d"):
            String(value)
        case let (.double(value), .some(spec)) where spec.hasSuffix("f"):
            String(format: "%\(spec)", value)
        default:
            nil
        }
    }
}
