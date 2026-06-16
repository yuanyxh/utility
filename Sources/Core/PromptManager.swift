import Foundation

/// 提示词管理器
/// 管理每个 AI 功能的提示词模板，支持变量替换
public final class PromptManager {
    public static let shared = PromptManager()

    private init() {}

    /// 获取指定功能的提示词，含变量替换
    /// - Parameters:
    ///   - feature: 功能名（如 "translate", "summarize"）
    ///   - variables: 替换变量字典，例如 `["source": "en", "target": "zh"]`
    public func prompt(for feature: String, variables: [String: String] = [:]) -> String {
        let config = ConfigManager.shared.config.prompts.templates[feature]
            ?? defaultPrompt(for: feature)
        return applyVariables(config, variables: variables)
    }

    // MARK: - Default Prompts

    private func defaultPrompt(for feature: String) -> String {
        switch feature {
        case "translate":
            return "你是一个翻译助手。请将以下文本从{source}翻译到{target}。只返回翻译结果，不要添加任何解释、引号或额外内容。"
        case "translate_auto":
            return "你是一个翻译助手。请检测以下文本的语言。如果原文是{first}则翻译成{second}；如果原文是{second}则翻译成{first}；如果原文是其他语言则翻译成{first}。只返回翻译结果，不要添加任何解释、引号或额外内容。"
        case "summarize":
            return "请用中文总结以下内容的要点，保持简洁。"
        case "rewrite":
            return "请用更专业的语气重写以下文本。"
        default:
            return ""
        }
    }

    // MARK: - Variable Substitution

    private func applyVariables(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, val) in variables {
            result = result.replacingOccurrences(of: "{\(key)}", with: val)
        }
        return result
    }
}
