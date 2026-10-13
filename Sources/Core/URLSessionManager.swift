import Foundation
import SystemConfiguration

/// Unified URLSession manager, automatically reads system proxy settings
final class URLSessionManager {
    static let shared = URLSessionManager()

    /// The session all network requests should use (goes through the system proxy when proxy is enabled)
    let session: URLSession

    /// A session that bypasses the proxy (for local loopback, etc.)
    let directSession: URLSession

    /// The read system proxy URL (used for injection into the Python process)
    private(set) var systemProxyURL: URL?

    // MARK: - Private Constants

    // kCFStreamProperty* is marked deprecated, but connectionProxyDictionary is still
    // the only official way to configure a proxy on URLSession; Apple provides no alternative API
    // Use string literals to avoid deprecation warnings
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

        // Read the system proxy
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

    /// Read proxy settings from macOS System Preferences
    static func readSystemProxy() -> URL? {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return nil
        }

        // Prefer the HTTPS proxy, then the HTTP proxy
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
