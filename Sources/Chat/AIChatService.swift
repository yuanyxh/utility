import Foundation

/// AI 对话服务 — 纯逻辑层，零视图依赖
/// 负责构建消息、注入 system prompt、管理流式请求生命周期
public final class AIChatService {
  public static let shared = AIChatService()
  private var currentTask: URLSessionDataTask?
  private let lock = NSLock()

  private init() {}

  /// 当前是否正在流式请求
  public var isStreaming: Bool {
    lock.lock()
    defer { lock.unlock() }
    return currentTask != nil
  }

  /// 取消当前请求
  public func cancel() {
    lock.lock()
    let task = currentTask
    currentTask = nil
    lock.unlock()
    task?.cancel()
  }

  /// 发送流式对话请求
  /// - Parameters:
  ///   - messages: 对话历史（不含 system prompt，由本方法自动添加）
  ///   - onToken: 每个增量文本回调（非空字符串）
  ///   - onComplete: 完成回调（失败时已输出的 token 保留，由 UI 追加错误信息）
  @discardableResult
  public func chat(
    messages: [OpenAIChatRequest.Message],
    onToken: @escaping (String) -> Void,
    onComplete: @escaping (Result<Void, Error>) -> Void
  ) -> URLSessionDataTask? {
    cancel()

    let config = ConfigManager.shared.config
    guard !config.ai.apiKey.isEmpty else {
      onComplete(.failure(AIChatError.missingAPIKey))
      return nil
    }

    var allMessages = messages
    if let system = chatSystemPrompt() {
      allMessages.insert(.init(role: "system", content: system), at: 0)
    }

    let request = OpenAIChatRequest(
      model: config.ai.model,
      messages: allMessages,
      stream: true
    )

    let client = OpenAIClient(apiKey: config.ai.apiKey)
    let task = client.stream(
      request: request,
      baseURL: config.ai.baseURL,
      onToken: onToken,
      onComplete: onComplete
    )
    lock.lock()
    currentTask = task
    lock.unlock()
    return task
  }

  // MARK: - Private

  private func chatSystemPrompt() -> String? {
    let p = PromptManager.shared.prompt(for: "chat")
    return p.isEmpty ? nil : p
  }
}

// MARK: - Errors

public enum AIChatError: Error, LocalizedError {
  case missingAPIKey

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return L10n.Translation.missingApiKey
    }
  }
}
