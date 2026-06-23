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
    let config =
      ConfigManager.shared.config.prompts.templates[feature]
      ?? defaultPrompt(for: feature)
    return applyVariables(config, variables: variables)
  }

  // MARK: - Default Prompts

  private func defaultPrompt(for feature: String) -> String {
    switch feature {
    case "translate":
      return L10n.Prompt.translate
    case "translate_auto":
      return L10n.Prompt.translateAuto
    case "chat":
      return L10n.Prompt.chat
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
