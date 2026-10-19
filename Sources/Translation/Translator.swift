import Foundation

/// AI translation client
public final class Translator {
    public static let shared = Translator()
    private init() {}

    // MARK: - System Prompt

    private func buildSystemPrompt(source: String, target: String) -> String {
        let config = ConfigManager.shared.config
        if !config.translation.prompt.isEmpty {
            var prompt = config.translation.prompt
                .replacingOccurrences(of: "{source}", with: source)
            if target == "auto" {
                prompt = prompt.replacingOccurrences(of: "{target}", with: "auto")
            } else {
                prompt = prompt.replacingOccurrences(of: "{target}", with: target)
            }
            return prompt
        }
        if target == "auto" {
            return PromptManager.shared.prompt(
                for: "translate_auto",
                variables: [
                    "first": config.translation.firstLang,
                    "second": config.translation.secondLang,
                ],
            )
        }
        return PromptManager.shared.prompt(
            for: "translate",
            variables: ["source": source, "target": target],
        )
    }

    // MARK: - Callback

    @discardableResult
    public func translate(
        text: String, source: String = "auto", target: String = "zh",
        completion: @escaping (String?, Error?) -> Void,
    ) -> URLSessionTask? {
        let config = ConfigManager.shared.config
        guard !config.ai.apiKey.isEmpty else {
            completion(nil, TranslationError.missingAPIKey)
            return nil
        }

        let client = OpenAIClient(apiKey: config.ai.apiKey)
        let request = OpenAIChatRequest(
            model: config.ai.model,
            messages: [
                .init(role: "system", content: buildSystemPrompt(source: source, target: target)),
                .init(role: "user", content: text),
            ],
            temperature: 0.1,
            thinking: .init(type: "disabled"),
        )

        client.chat(request: request, baseURL: config.ai.baseURL) { result in
            switch result {
            case let .success(response):
                completion(response.choices.first?.message.content ?? "", nil)
            case let .failure(error):
                completion(nil, error)
            }
        }
        return nil
    }

    // MARK: - Async

    public func translate(text: String, source: String = "auto", target: String = "zh") async throws
        -> String
    {
        let config = ConfigManager.shared.config
        guard !config.ai.apiKey.isEmpty else {
            throw TranslationError.missingAPIKey
        }

        let client = OpenAIClient(apiKey: config.ai.apiKey)
        let request = OpenAIChatRequest(
            model: config.ai.model,
            messages: [
                .init(role: "system", content: buildSystemPrompt(source: source, target: target)),
                .init(role: "user", content: text),
            ],
            temperature: 0.1,
            thinking: .init(type: "disabled"),
        )

        let response = try await client.chat(request: request, baseURL: config.ai.baseURL)
        return response.choices.first?.message.content ?? ""
    }
}

// MARK: - Errors

public enum TranslationError: Error, LocalizedError {
    case missingAPIKey
    case apiError

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: L10n.Error.missingApiKey
        case .apiError: L10n.Error.apiFailed
        }
    }
}
