import Foundation

// MARK: - Request

public struct OpenAIChatRequest: Codable {
    public let model: String
    public let messages: [Message]
    public let temperature: Double?
    public let topP: Double?
    public let maxTokens: Int?
    public let stop: [String]?
    public let thinking: ThinkingConfig?
    public let reasoningEffort: String?
    public let presencePenalty: Double?
    public let frequencyPenalty: Double?

    public struct Message: Codable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct ThinkingConfig: Codable {
        public let type: String

        public init(type: String) {
            self.type = type
        }
    }

    public init(
        model: String,
        messages: [Message],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stop: [String]? = nil,
        thinking: ThinkingConfig? = nil,
        reasoningEffort: String? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stop = stop
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stop, thinking
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
    }
}

// MARK: - Response

public struct OpenAIChatResponse: Codable {
    public let id: String?
    public let model: String?
    public let choices: [Choice]

    public struct Choice: Codable {
        public let index: Int?
        public let message: Message
        public let finishReason: String?

        public struct Message: Codable {
            public let role: String?
            public let content: String?
            public let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case role, content
                case reasoningContent = "reasoning_content"
            }
        }

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }
}

// MARK: - Client

public final class OpenAIClient {
    private let session: URLSession
    private let apiKey: String

    public init(apiKey: String, timeout: TimeInterval = 120) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }

    // MARK: - Request builder

    private func makeURLRequest(_ req: OpenAIChatRequest, baseURL: String) throws -> URLRequest {
        guard let url = URL(string: baseURL)?.appendingPathComponent("chat/completions") else {
            throw OpenAIError.invalidURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        #if DEBUG
            encoder.outputFormatting = .sortedKeys
        #endif
        urlRequest.httpBody = try encoder.encode(req)
        return urlRequest
    }

    // MARK: - Callback

    @discardableResult
    public func chat(
        request req: OpenAIChatRequest,
        baseURL: String,
        completion: @escaping (Result<OpenAIChatResponse, Error>) -> Void
    ) -> URLSessionDataTask? {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(req, baseURL: baseURL)
        } catch {
            completion(.failure(error))
            return nil
        }

        #if DEBUG
            let startTime = CFAbsoluteTimeGetCurrent()
            let model = req.model
            let endpoint = URL(string: baseURL)?.appendingPathComponent("chat/completions").absoluteString ?? baseURL
        #endif

        let task = session.dataTask(with: urlRequest) { data, response, error in
            #if DEBUG
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            #endif
            if let error = error {
                #if DEBUG
                    debugLog("[OpenAI] \(endpoint) \(model) failed \(String(format: "%.0f", elapsed))ms: \(error.localizedDescription)")
                #endif
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(OpenAIError.invalidResponse))
                return
            }
            guard httpResponse.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                #if DEBUG
                    debugLog("[OpenAI] \(endpoint) \(model) HTTP \(httpResponse.statusCode) \(String(format: "%.0f", elapsed))ms")
                #endif
                completion(.failure(OpenAIError.httpError(httpResponse.statusCode, body)))
                return
            }
            guard let data = data else {
                completion(.failure(OpenAIError.emptyData))
                return
            }
            do {
                let result = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
                #if DEBUG
                    let contentLen = result.choices.first?.message.content?.count ?? 0
                    debugLog("[OpenAI] \(endpoint) \(model) OK \(String(format: "%.0f", elapsed))ms content=\(contentLen)")
                #endif
                completion(.success(result))
            } catch {
                #if DEBUG
                    debugLog("[OpenAI] \(model) decode failed after \(String(format: "%.0f", elapsed))ms")
                #endif
                completion(.failure(OpenAIError.decodeFailed(error, data)))
            }
        }
        task.resume()
        return task
    }

    // MARK: - Async

    public func chat(request req: OpenAIChatRequest, baseURL: String) async throws -> OpenAIChatResponse {
        #if DEBUG
            let startTime = CFAbsoluteTimeGetCurrent()
            let model = req.model
            let endpoint = URL(string: baseURL)?.appendingPathComponent("chat/completions").absoluteString ?? baseURL
            defer {
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                debugLog("[OpenAI] \(endpoint) \(model) done \(String(format: "%.0f", elapsed))ms")
            }
        #endif

        let urlRequest = try makeURLRequest(req, baseURL: baseURL)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.httpError(httpResponse.statusCode, body)
        }

        return try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
    }
}

// MARK: - Errors

public enum OpenAIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case emptyData
    case httpError(Int, String)
    case encodeFailed(Error)
    case decodeFailed(Error, Data)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.Translation.invalidURL
        case .invalidResponse:
            return L10n.Translation.invalidResponse
        case .emptyData:
            return L10n.Translation.emptyResponse
        case let .httpError(code, body):
            return "HTTP \(code): \(body.prefix(200))"
        case let .encodeFailed(error):
            return L10n.Translation.encodeFailed(error.localizedDescription)
        case let .decodeFailed(error, data):
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            return L10n.Translation.parseFailed("\(error.localizedDescription)\n\(preview)")
        }
    }
}
