import Foundation

/// Prompt manager.
///
/// Templates have four sources, in priority from high to low:
///
/// 1. `translation.prompt` — translation-specific inline template (`Translator` reads it directly, not through this class)
/// 2. `prompts.templates[feature]` — inline template in config
/// 3. File: `~/.config/utility/prompts/<feature>.md` (user override, **language-independent**)
///    → `MCPScripts/prompts/<lang>/<feature>.md` (bundled, falls back by current language → `zh-Hans` baseline)
/// 4. `L10n` built-in text (`Sources/Resources/<lang>.json`)
///
/// Layer 3 **shares the same directory and the same contract** with the Python-side `prompt_loader.py`:
/// the front-matter declares `name` / `placeholders` / `json_keys`, and both consumers pick files by the
/// same rules and run the same self-checks. So "switching a language" and "editing one prompt" are the same
/// thing on both sides, no need to change two copies.
///
/// Layer 4 is not a "second copy of the text" but a **fallback for a broken install**: `MCPScripts/prompts/`
/// is bundled, and a missing file means an incomplete install. Without the fallback, what gets sent to the
/// model would be an empty system prompt—harder to diagnose than a hard failure (it shows as "the model
/// gives irrelevant answers" rather than "translation error"). The two layers' contents are asserted
/// byte-for-byte by `scripts/check-router-config-contract.py`, so they won't drift.
public final class PromptManager {
    public static let shared = PromptManager()

    private init() {}

    /// Baseline language: fall back to it when the current language has no such template.
    /// Same value as `prompt_loader.FALLBACK_LANG`—the two sides' judgment of "is this language present" must agree.
    static let fallbackLanguage = "zh-Hans"

    /// Prompt directory name (under `MCPScripts/`).
    private static let promptsDir = "prompts"

    /// Get the prompt for the specified feature, with variable substitution.
    /// - Parameters:
    ///   - feature: feature name (e.g. "translate", "translate_auto")
    ///   - variables: substitution variable dictionary, e.g. `["source": "en", "target": "zh"]`
    public func prompt(for feature: String, variables: [String: String] = [:]) -> String {
        if let custom = ConfigManager.shared.config.prompts.templates[feature],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Self.applyVariables(custom, variables: variables)
        }
        let template = Self.loadTemplate(feature: feature)
        Self.warnUncoveredArguments(template, feature: feature, variables: variables)
        return Self.applyVariables(template.text, variables: variables)
    }

    // MARK: - Template

    /// A renderable template and its declaration.
    struct Template {
        let text: String
        /// Placeholders declared by the file; `nil` = no declaration (config inline template and L10n fallback), no override check
        let placeholders: [String]?
        /// Origin path, used only for log locating
        let origin: String
    }

    /// Pick the template by priority: user override dir → built-in dir (each by current language → baseline language).
    /// If all candidates are unusable, fall back to `L10n`—not silently, and not sending an empty prompt to the model.
    static func loadTemplate(feature: String) -> Template {
        let language = currentLanguage()
        guard isValidFeature(feature) else {
            debugLog("[PromptManager] invalid feature name (only lowercase letters/digits/underscores allowed): \(feature)")
            return l10nTemplate(feature: feature)
        }

        for candidate in candidatePaths(feature: feature, language: language) {
            guard let raw = try? String(contentsOfFile: candidate.path, encoding: .utf8) else {
                debugLog("[PromptManager] failed to read template: \(candidate.path)")
                continue
            }
            // On parse failure (contract violation) continue to the next candidate: a broken user override
            // should fall back to the built-in, not stop translation. The real problem was already logged in parseTemplate.
            guard let parsed = parseTemplate(raw, feature: feature, path: candidate.path) else {
                continue
            }
            // Only built-in templates have a "language fallback"; the user override is language-independent and must not be reported as a fallback
            if let lang = candidate.lang, lang != language {
                debugLog(
                    "[PromptManager] \(feature): no template for language \(language), falling back to \(lang) (\(candidate.path))",
                )
            }
            return Template(text: parsed.text, placeholders: parsed.placeholders, origin: candidate.path)
        }

        debugLog("[PromptManager] \(feature): no usable template file for language \(language), falling back to L10n built-in text")
        return l10nTemplate(feature: feature)
    }

    /// Candidate files: (path, language). `lang` being `nil` means **language-independent**—the user override takes this path.
    ///
    /// The language dimension of the two is **intentionally different**: built-in templates target "users who may be
    /// native speakers of different languages", so they are split by language directory and fall back to the baseline
    /// when that language is missing; the user override is a single file the user controls—whoever writes the prompt
    /// has only one native language, so making "which directory it goes in" depend on the UI language is both
    /// meaningless and broken when the language is switched.
    ///
    /// The order must match `prompt_loader._candidate_paths`: once the two sides interpret the same directory
    /// differently, you get an inexplicable combination like "Python used the user override, Swift used the built-in".
    static func candidatePaths(feature: String, language: String) -> [(path: String, lang: String?)] {
        var candidates: [(path: String, lang: String?)] = []
        let override = AppPaths.configDir
            .appendingPathComponent(promptsDir)
            .appendingPathComponent("\(feature).md")
            .path
        candidates.append((override, nil))

        var langs = [language]
        if language != fallbackLanguage {
            langs.append(fallbackLanguage)
        }
        for lang in langs {
            if let path = MCPScriptsResources.path(relative: "\(promptsDir)/\(lang)/\(feature).md") {
                candidates.append((path, lang))
            }
        }
        return candidates
    }

    /// Current language: same source as the `UTILITY_LANG` injected to Python (`L10n` is the sole criterion).
    private static func currentLanguage() -> String {
        L10n.resolvedLanguage(configured: ConfigManager.shared.config.general.language)
    }

    /// L10n built-in text fallback; unknown feature returns an empty string (consistent with the old `defaultPrompt` behavior).
    private static func l10nTemplate(feature: String) -> Template {
        let text: String = switch feature {
        case "translate": L10n.Prompt.translate
        case "translate_auto": L10n.Prompt.translateAuto
        default: ""
        }
        if text.isEmpty {
            debugLog("[PromptManager] unknown feature and no built-in text: \(feature)")
        }
        return Template(text: text, placeholders: nil, origin: "L10n")
    }

    // MARK: - Contract parsing (same rules as prompt_loader)

    /// Parse a template file (front-matter + body) and self-check against the contract; on violation log and return nil.
    ///
    /// Contract (aligned line by line with `prompt_loader._parse_file`):
    /// - The head is `---\n<key: value>\n---\n`, keys are the flat `name` / `placeholders` / `json_keys`
    /// - `name` must equal feature—a misplaced file is exposed immediately rather than silently using the wrong prompt
    /// - `placeholders` declared must match the `{placeholder}` actually present (file self-check)
    static func parseTemplate(
        _ raw: String,
        feature: String,
        path: String,
    ) -> (text: String, placeholders: [String])? {
        guard let frontMatter = frontMatterRegex,
              let match = frontMatter.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))
        else {
            debugLog("[PromptManager] \(path): missing front-matter (--- name/placeholders ---)")
            return nil
        }

        let ns = raw as NSString
        let metaRaw = ns.substring(with: match.range(at: 1))
        let text = ns.substring(from: match.range.location + match.range.length)

        var meta: [String: String] = [:]
        for line in metaRaw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let entry = parseKeyValue(trimmed) else {
                debugLog("[PromptManager] \(path): cannot parse front-matter line \(trimmed)")
                return nil
            }
            meta[entry.key] = entry.value
        }

        let name = (meta["name"] ?? "").trimmingCharacters(in: .whitespaces)
        guard name == feature else {
            debugLog("[PromptManager] \(path): name=\(name) does not match requested feature=\(feature)")
            return nil
        }

        let declared = parseList(meta["placeholders"] ?? "")
        let found = placeholders(in: text)
        guard Set(declared) == Set(found) else {
            debugLog(
                "[PromptManager] \(path): placeholders declaration does not match actual"
                    + " (declared \(declared.sorted()) / actual \(found.sorted()))",
            )
            return nil
        }
        return (text, declared)
    }

    private static func parseKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let regex = keyValueRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else {
            return nil
        }
        let ns = line as NSString
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    /// `[a, b]` → ["a", "b"] (flat form, no YAML dependency introduced).
    private static func parseList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let regex = listRegex,
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else {
            return []
        }
        let inner = (trimmed as NSString).substring(with: match.range(at: 1))
        return inner.split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
    }

    /// Placeholders actually present in the body (deduplicated, order preserved).
    private static func placeholders(in text: String) -> [String] {
        guard let regex = placeholderRegex else { return [] }
        let ns = text as NSString
        var seen: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private static func isValidFeature(_ feature: String) -> Bool {
        guard let regex = featureRegex else { return false }
        return regex.firstMatch(in: feature, range: NSRange(feature.startIndex..., in: feature)) != nil
    }

    // MARK: - Variable substitution

    /// Replace `{placeholder}` by name in a single pass; unregistered `{…}` are kept as-is.
    ///
    /// Not using per-key `replacingOccurrences`: a substituted value containing `{target}` would be
    /// replaced again in a later round (any other placeholder in user-defined text would trigger this).
    /// Same semantics as `prompt_loader.render`.
    static func applyVariables(_ template: String, variables: [String: String]) -> String {
        guard !variables.isEmpty, let regex = placeholderRegex else { return template }
        let ns = template as NSString
        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: template, range: NSRange(location: 0, length: ns.length)) {
            match, _, _ in
            guard let match else { return }
            let name = ns.substring(with: match.range(at: 1))
            guard let value = variables[name] else { return }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += value
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Log when a template declares placeholders but the call passes no arguments—a missing argument sends the
    /// `{placeholder}` to the model as-is, showing as "the model saw a strange template variable", which can only
    /// be located here.
    private static func warnUncoveredArguments(
        _ template: Template,
        feature: String,
        variables: [String: String],
    ) {
        guard let declared = template.placeholders else { return }
        let missing = declared.filter { variables[$0] == nil }
        guard !missing.isEmpty else { return }
        debugLog(
            "[PromptManager] \(feature): call missing arguments \(missing)"
                + " (template declares \(declared), \(template.origin))",
        )
    }

    // MARK: - Regexes (contract expression, same name and meaning as prompt_loader)

    /// : front-matter: the file must start with `---` and end with `---`
    private static let frontMatterRegex = makeRegex(
        #"\A---\r?\n(.*?)\r?\n---\r?\n"#,
        options: [.dotMatchesLineSeparators],
    )
    private static let keyValueRegex = makeRegex(#"^([a-zA-Z_]+)\s*:\s*(.*)$"#)
    private static let listRegex = makeRegex(#"^\[(.*)\]$"#)
    /// Placeholder in the body: only the `[A-Za-z0-9_]` form is recognized, so JSON's `{"action": …}` is not misidentified
    private static let placeholderRegex = makeRegex(#"\{([a-zA-Z_][a-zA-Z0-9_]*)\}"#)
    /// feature name (used for filename concatenation, prevents directory traversal)
    private static let featureRegex = makeRegex(#"^[a-z][a-z0-9_]*$"#)

    /// A regex compile failure must not be silent—it makes the whole prompt fall back to L10n, which looks like "it just didn't take effect".
    private static func makeRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = [],
    ) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            debugLog("[PromptManager] regex compile failed \(pattern): \(error)")
            return nil
        }
    }
}
