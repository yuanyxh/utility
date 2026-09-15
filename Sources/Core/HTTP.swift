import Foundation

/// 统一 HTTP 请求工具，类似 axios
/// - 默认 User-Agent、超时、JSON Content-Type
/// - 重定向由 URLSession 自动跟随
/// - 非 2xx 状态码抛 HTTPError
/// - retryCount > 0 时失败自动重试
enum HTTP {
    /// 防反爬 UA，不含版本号和仓库信息
    static let defaultUserAgent = "Utility (macOS)"

    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [AnyHashable: Any]
    }

    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    /// 请求配置 — 一个 struct 收束所有控制参数
    struct RequestConfig {
        var method: Method = .get
        var url: URL
        var headers: [String: String] = [:]
        var body: Data?
        var timeout: TimeInterval = 30
        var retryCount: Int = 0
    }

    /// 唯一入口：接受完整的 RequestConfig
    static func request(_ config: RequestConfig) async throws -> Response {
        var lastError: Error?
        let maxAttempts = max(config.retryCount + 1, 1)

        for _ in 0 ..< maxAttempts {
            do {
                var req = URLRequest(url: config.url)
                req.httpMethod = config.method.rawValue
                req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = config.timeout

                for (key, value) in config.headers {
                    req.setValue(value, forHTTPHeaderField: key)
                }

                if let body = config.body {
                    req.httpBody = body
                    if config.headers["Content-Type"] == nil {
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }

                let (data, response) = try await URLSessionManager.shared.session.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw HTTPError.invalidResponse
                }
                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    throw HTTPError.httpError(httpResponse.statusCode, bodyStr)
                }
                return Response(
                    data: data,
                    statusCode: httpResponse.statusCode,
                    headers: httpResponse.allHeaderFields
                )
            } catch {
                lastError = error
                // 继续下一次重试
            }
        }

        throw lastError ?? HTTPError.unknown
    }

    // MARK: - Convenience

    static func get(
        url: URL,
        configure: (inout RequestConfig) -> Void = { _ in }
    ) async throws -> Response {
        var cfg = RequestConfig(method: .get, url: url)
        configure(&cfg)
        return try await request(cfg)
    }

    static func post(
        url: URL,
        body: Data? = nil,
        configure: (inout RequestConfig) -> Void = { _ in }
    ) async throws -> Response {
        var cfg = RequestConfig(method: .post, url: url, body: body)
        configure(&cfg)
        return try await request(cfg)
    }
}

// MARK: - Errors

enum HTTPError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid HTTP response"
        case let .httpError(code, body):
            "HTTP \(code): \(body.prefix(200))"
        case .unknown:
            "Unknown HTTP error"
        }
    }
}
