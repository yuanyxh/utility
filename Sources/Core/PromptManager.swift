import Foundation

/// 提示词管理器。
///
/// 模板有四个来源，优先级从高到低：
///
/// 1. `translation.prompt` —— 翻译专用内联模板（`Translator` 直接读，不经本类）
/// 2. `prompts.templates[feature]` —— 配置里的内联模板
/// 3. 文件：`~/.config/utility/prompts/<feature>.md`（用户覆盖，**与语言无关**）
///    → `MCPScripts/prompts/<lang>/<feature>.md`（随包内置，按当前语言 → `zh-Hans` 基线回退）
/// 4. `L10n` 内置文案（`Sources/Resources/<lang>.json`）
///
/// 第 3 层与 Python 侧 `prompt_loader.py` **共用同一目录、同一契约**：front-matter 里
/// 声明 `name` / `placeholders` / `json_keys`，两个消费方按同一规则挑文件、做同样的
/// 自校验。这样「换个语言」「改一句提示词」在两侧是同一件事，不必各改一份。
///
/// 第 4 层不是「第二份文案」，而是**安装损坏时的兜底**：`MCPScripts/prompts/` 随包分发，
/// 缺失属安装不完整。此时若无兜底，发给模型的将是一段空 system prompt——比直接失败更难
/// 排查（表现为「模型答非所问」而非「翻译报错」）。两层内容由
/// `scripts/check-router-config-contract.py` 断言逐字一致，不会漂移。
public final class PromptManager {
    public static let shared = PromptManager()

    private init() {}

    /// 基线语言：当前语言没有该模板时回退它。
    /// 与 `prompt_loader.FALLBACK_LANG` 同值——两侧对「有没有这个语言」的判断必须一致。
    static let fallbackLanguage = "zh-Hans"

    /// 提示词目录名（`MCPScripts/` 下）。
    private static let promptsDir = "prompts"

    /// 获取指定功能的提示词，含变量替换。
    /// - Parameters:
    ///   - feature: 功能名（如 "translate", "translate_auto"）
    ///   - variables: 替换变量字典，例如 `["source": "en", "target": "zh"]`
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

    // MARK: - 模板

    /// 一份可渲染的模板及其声明。
    struct Template {
        let text: String
        /// 文件声明的占位符；`nil` = 无声明（配置内联模板与 L10n 兜底），不做覆盖校验
        let placeholders: [String]?
        /// 来源路径，仅用于日志定位
        let origin: String
    }

    /// 按优先级取模板：用户覆盖目录 → 内置目录（各自按 当前语言 → 基线语言）。
    /// 候选全不可用则回退 `L10n`——不静默、也不把空提示词发给模型。
    static func loadTemplate(feature: String) -> Template {
        let language = currentLanguage()
        guard isValidFeature(feature) else {
            debugLog("[PromptManager] feature 名非法（只允许小写字母/数字/下划线）: \(feature)")
            return l10nTemplate(feature: feature)
        }

        for candidate in candidatePaths(feature: feature, language: language) {
            guard let raw = try? String(contentsOfFile: candidate.path, encoding: .utf8) else {
                debugLog("[PromptManager] 模板读取失败: \(candidate.path)")
                continue
            }
            // 解析失败（契约违反）时继续找下一个候选：用户覆盖写坏了应回退到内置，
            // 而不是让翻译功能停摆。真正的问题已在 parseTemplate 里记了日志。
            guard let parsed = parseTemplate(raw, feature: feature, path: candidate.path) else {
                continue
            }
            // 只有内置模板才有「语言回退」一说；用户覆盖与语言无关，不该被报成回退
            if let lang = candidate.lang, lang != language {
                debugLog(
                    "[PromptManager] \(feature): 语言 \(language) 无该模板，回退 \(lang)（\(candidate.path)）",
                )
            }
            return Template(text: parsed.text, placeholders: parsed.placeholders, origin: candidate.path)
        }

        debugLog("[PromptManager] \(feature): 语言 \(language) 下无可用模板文件，回退 L10n 内置文案")
        return l10nTemplate(feature: feature)
    }

    /// 候选文件：(路径, 语言)。`lang` 为 `nil` 表示**与语言无关**——用户覆盖走这条。
    ///
    /// 两处的语言维度**有意不同**：内置模板面向「使用者可能是不同母语的人」，故按语言
    /// 分目录、缺该语言时回退基线；用户覆盖是用户自己控制的一份文件——写 prompt 的人只有
    /// 一种母语，让它「放哪个目录」取决于界面语言既无意义、又会因切换语言而失效。
    ///
    /// 顺序必须与 `prompt_loader._candidate_paths` 一致：两侧对同一目录的解释一旦不同，
    /// 就会出现「Python 用了用户覆盖、Swift 用了内置」这种没法解释的组合。
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

    /// 当前语言：与注入给 Python 的 `UTILITY_LANG` 同源（`L10n` 是唯一判据）。
    private static func currentLanguage() -> String {
        L10n.resolvedLanguage(configured: ConfigManager.shared.config.general.language)
    }

    /// L10n 内置文案兜底；未知 feature 返回空串（与 `defaultPrompt` 旧行为一致）。
    private static func l10nTemplate(feature: String) -> Template {
        let text: String = switch feature {
        case "translate": L10n.Prompt.translate
        case "translate_auto": L10n.Prompt.translateAuto
        default: ""
        }
        if text.isEmpty {
            debugLog("[PromptManager] 未知 feature 且无内置文案: \(feature)")
        }
        return Template(text: text, placeholders: nil, origin: "L10n")
    }

    // MARK: - 契约解析（与 prompt_loader 同规则）

    /// 解析模板文件（front-matter + 正文）并按契约自校验，违反则记日志并返回 nil。
    ///
    /// 契约（逐条对齐 `prompt_loader._parse_file`）：
    /// - 首部是 `---\n<键: 值>\n---\n`，键为扁平的 `name` / `placeholders` / `json_keys`
    /// - `name` 必须等于 feature——文件放错位置会立即暴露，而不是静默用错提示词
    /// - `placeholders` 声明与实际出现的 `{占位符}` 必须一致（文件自校验）
    static func parseTemplate(
        _ raw: String,
        feature: String,
        path: String,
    ) -> (text: String, placeholders: [String])? {
        guard let frontMatter = frontMatterRegex,
              let match = frontMatter.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))
        else {
            debugLog("[PromptManager] \(path): 缺少 front-matter（--- name/placeholders ---）")
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
                debugLog("[PromptManager] \(path): front-matter 行无法解析 \(trimmed)")
                return nil
            }
            meta[entry.key] = entry.value
        }

        let name = (meta["name"] ?? "").trimmingCharacters(in: .whitespaces)
        guard name == feature else {
            debugLog("[PromptManager] \(path): name=\(name) 与请求的 feature=\(feature) 不一致")
            return nil
        }

        let declared = parseList(meta["placeholders"] ?? "")
        let found = placeholders(in: text)
        guard Set(declared) == Set(found) else {
            debugLog(
                "[PromptManager] \(path): placeholders 声明与实际不符"
                    + "（声明 \(declared.sorted()) / 实际 \(found.sorted())）",
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

    /// `[a, b]` → ["a", "b"]（扁平写法，不引入 YAML 依赖）。
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

    /// 正文里实际出现的占位符（去重保序）。
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

    // MARK: - 变量替换

    /// 按名字一次性替换 `{占位符}`；未登记的 `{…}` 原样保留。
    ///
    /// 不用逐个键 `replacingOccurrences`：那样替换进来的值若含 `{target}`，会被后续轮次
    /// 再次替换（用户自定义文案里出现别的占位符就中招）。与 `prompt_loader.render` 同语义。
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

    /// 模板声明了占位符、调用却没给实参时记日志——缺参会把 `{占位符}` 原样发给模型，
    /// 表现为「模型看到了奇怪的模板变量」，只有在这里能定位到。
    private static func warnUncoveredArguments(
        _ template: Template,
        feature: String,
        variables: [String: String],
    ) {
        guard let declared = template.placeholders else { return }
        let missing = declared.filter { variables[$0] == nil }
        guard !missing.isEmpty else { return }
        debugLog(
            "[PromptManager] \(feature): 调用缺少实参 \(missing)"
                + "（模板声明 \(declared)，\(template.origin)）",
        )
    }

    // MARK: - 正则（契约表达，与 prompt_loader 同名同义）

    /// : front-matter：文件必须以 `---` 开头、`---` 结束
    private static let frontMatterRegex = makeRegex(
        #"\A---\r?\n(.*?)\r?\n---\r?\n"#,
        options: [.dotMatchesLineSeparators],
    )
    private static let keyValueRegex = makeRegex(#"^([a-zA-Z_]+)\s*:\s*(.*)$"#)
    private static let listRegex = makeRegex(#"^\[(.*)\]$"#)
    /// 正文里的占位符：只认「字母数字下划线」形态，故 JSON 的 `{"action": …}` 不会被误判
    private static let placeholderRegex = makeRegex(#"\{([a-zA-Z_][a-zA-Z0-9_]*)\}"#)
    /// feature 名（文件名拼接用，防目录穿越）
    private static let featureRegex = makeRegex(#"^[a-z][a-z0-9_]*$"#)

    /// 正则编译失败不该静默——它会让提示词整体回退到 L10n，看起来「只是没生效」。
    private static func makeRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = [],
    ) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            debugLog("[PromptManager] 正则编译失败 \(pattern): \(error)")
            return nil
        }
    }
}
