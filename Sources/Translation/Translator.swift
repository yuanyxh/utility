import Foundation

/// AI 翻译客户端
/// 使用 OpenAI 兼容 API，支持自定义提示词和变量替换
public final class Translator {
    public static let shared = Translator()
    private let session = URLSession.shared

    private init() {}

    /// 翻译文本
    /// - Parameters:
    ///   - text: 待翻译文本
    ///   - source: 源语言代码（如 "en", "auto"）
    ///   - target: 目标语言代码（如 "zh", "auto" — auto 时由 AI 根据第一/第二语言判断）
    /// - Returns: 翻译结果
    public func translate(text: String, source: String = "auto", target: String = "zh") async throws -> String {
        let config = ConfigManager.shared.config
        guard !config.ai.apiKey.isEmpty else {
            throw TranslationError.missingAPIKey
        }

        // 构建 system prompt：优先用户自定义，否则用默认模板
        let systemPrompt: String
        let effectiveTarget: String
        if !config.translation.prompt.isEmpty {
            // 用户自定义提示词中的变量替换
            var prompt = config.translation.prompt
                .replacingOccurrences(of: "{source}", with: source)
            if target == "auto" {
                // target 为 auto：用 firstLang/secondLang 说明翻译规则
                prompt = prompt
                    .replacingOccurrences(of: "{target}", with: "auto")
                effectiveTarget = "auto"
            } else {
                prompt = prompt.replacingOccurrences(of: "{target}", with: target)
                effectiveTarget = target
            }
            systemPrompt = prompt
        } else {
            if target == "auto" {
                systemPrompt = PromptManager.shared.prompt(for: "translate_auto",
                    variables: ["first": config.translation.firstLang,
                                "second": config.translation.secondLang])
                effectiveTarget = "auto"
            } else {
                systemPrompt = PromptManager.shared.prompt(for: "translate",
                    variables: ["source": source, "target": target])
                effectiveTarget = target
            }
        }

        let url = URL(string: config.ai.baseURL)!
            .appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.ai.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.ai.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "stream": false,
            "temperature": 0.1
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TranslationError.apiError
        }

        struct APIResponse: Codable {
            let choices: [Choice]
        }
        struct Choice: Codable {
            let message: Message
        }
        struct Message: Codable {
            let content: String
        }

        let apiResp = try JSONDecoder().decode(APIResponse.self, from: data)
        return apiResp.choices.first?.message.content ?? ""
    }
}

// MARK: - Errors

public enum TranslationError: Error, LocalizedError {
    case missingAPIKey
    case apiError

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请在配置文件中设置 AI API Key (ai.apiKey)"
        case .apiError: return "翻译 API 请求失败，请检查网络和 API 配置"
        }
    }
}
