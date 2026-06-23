import Foundation

/// 独立 SSE（Server-Sent Events）解析器
/// 逐行解析 `data: {...}` 帧，提取 content delta 并回调
public final class SSEParser {
  private var buffer = ""

  public init() {}

  /// 喂入 Data chunk，回调每个解析到的 token
  /// - Parameters:
  ///   - data: 流式响应 chunk
  ///   - onToken: 每个 content delta（非空字符串）
  ///   - onComplete: 收到 `[DONE]` 信号时调用
  public func feed(
    _ data: Data,
    onToken: @escaping (String) -> Void,
    onComplete: @escaping () -> Void
  ) {
    guard let str = String(data: data, encoding: .utf8) else { return }
    buffer += str

    let lines = buffer.components(separatedBy: "\n")
    buffer = lines.last ?? ""

    for line in lines.dropLast() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("data: ") else { continue }

      let jsonStr = String(trimmed.dropFirst(6))
      if jsonStr == "[DONE]" {
        onComplete()
        return
      }
      guard let data = jsonStr.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = json["choices"] as? [[String: Any]],
        let delta = choices.first?["delta"] as? [String: Any],
        let content = delta["content"] as? String,
        !content.isEmpty
      else { continue }

      onToken(content)
    }
  }
}
