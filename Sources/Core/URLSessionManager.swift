import Foundation
import SystemConfiguration

/// 统一 URLSession 管理器，自动读取系统代理配置
final class URLSessionManager {
    static let shared = URLSessionManager()

    /// 所有网络请求应使用的 session（启用代理时走系统代理）
    let session: URLSession

    /// 不走代理的 session（用于本地 loopback 等）
    let directSession: URLSession

    /// 读取到的系统代理 URL（供 Python 进程注入使用）
    private(set) var systemProxyURL: URL?

    // MARK: - 私有常量

    // kCFStreamProperty* 标记为弃用，但 connectionProxyDictionary 仍是
    // URLSession 配置代理的唯一官方方式，Apple 未提供替代 API
    // 使用字符串字面量避免弃用警告
    private static let proxyHTTPHost = "kCFStreamPropertyHTTPProxyHost"
    private static let proxyHTTPPort = "kCFStreamPropertyHTTPProxyPort"
    private static let proxyHTTPSHost = "kCFStreamPropertyHTTPSProxyHost"
    private static let proxyHTTPSPort = "kCFStreamPropertyHTTPSProxyPort"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 4

        let directConfig = URLSessionConfiguration.default
        directConfig.timeoutIntervalForRequest = 30

        // 读取系统代理
        systemProxyURL = Self.readSystemProxy()

        let proxyEnabled = ConfigManager.shared.config.general.proxyEnabled
        if let proxy = systemProxyURL, proxyEnabled,
           let host = proxy.host, let port = proxy.port
        {
            config.connectionProxyDictionary = [
                Self.proxyHTTPHost: host,
                Self.proxyHTTPPort: port,
                Self.proxyHTTPSHost: host,
                Self.proxyHTTPSPort: port,
            ]
        }

        session = URLSession(configuration: config)
        directSession = URLSession(configuration: directConfig)
    }

    /// 从 macOS 系统偏好设置读取代理配置
    static func readSystemProxy() -> URL? {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return nil
        }

        // 优先 HTTPS 代理，其次 HTTP 代理
        if proxies["HTTPSEnable"] as? Bool == true,
           let host = proxies["HTTPSProxy"] as? String
        {
            let port = proxies["HTTPSPort"] as? Int ?? 443
            return URL(string: "http://\(host):\(port)")
        }

        if proxies["HTTPEnable"] as? Bool == true,
           let host = proxies["HTTPProxy"] as? String
        {
            let port = proxies["HTTPPort"] as? Int ?? 8080
            return URL(string: "http://\(host):\(port)")
        }

        return nil
    }
}
