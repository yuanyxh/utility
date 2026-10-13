import Foundation

/// Unified HTTP request utility, similar to axios
/// - Default User-Agent, timeout, JSON Content-Type
/// - Redirects are followed automatically by URLSession
/// - Non-2xx status codes throw HTTPError
/// - Auto-retry on failure when retryCount > 0
enum HTTP {
    /// Anti-scraping UA, containing no version number or repository info
    static let defaultUserAgent = "Utility (macOS)"

    /// Local loopback address. Always use the literal `127.0.0.1` rather than `localhost`: the latter may resolve to `::1`,
    /// while local services (MCP server / token proxy) listen only on IPv4. Local clients always use this one.
    static let localHost = "127.0.0.1"

    /// Local service base URL, e.g. `http://127.0.0.1:8613`
    static func localBaseURL(port: Int) -> String {
        "http://\(localHost):\(port)"
    }

    /// Local service URL (may include a path), e.g. `HTTP.localURL(port: 8613, path: "/usage/summary")`
    static func localURL(port: Int, path: String = "") -> URL? {
        URL(string: localBaseURL(port: port) + path)
    }

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

    /// Request config — a single struct gathering all control parameters
    struct RequestConfig {
        var method: Method = .get
        var url: URL
        var headers: [String: String] = [:]
        var body: Data?
        var timeout: TimeInterval = 30
        var retryCount: Int = 0
    }

    /// Sole entry point: accepts a complete RequestConfig
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
                    headers: httpResponse.allHeaderFields,
                )
            } catch {
                lastError = error
                // Continue to the next retry
            }
        }

        throw lastError ?? HTTPError.unknown
    }

    // MARK: - Convenience

    static func get(
        url: URL,
        configure: (inout RequestConfig) -> Void = { _ in },
    ) async throws -> Response {
        var cfg = RequestConfig(method: .get, url: url)
        configure(&cfg)
        return try await request(cfg)
    }

    static func post(
        url: URL,
        body: Data? = nil,
        configure: (inout RequestConfig) -> Void = { _ in },
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
