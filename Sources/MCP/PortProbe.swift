import Foundation

/// 本地端口探测——常驻服务在「配置端口为 0（自动检测）」时挑选可用端口。
///
/// 独立成工具的原因有二：
///
/// 1. 这段逻辑原先在 `MCPProcessManager` 与 `TokenProxyManager` 中逐字重复
///    37 行，只差一个起始端口常量。
/// 2. 端口**必须只解析一次并缓存**。探测手段是「bind 测试」，而服务起来之后
///    自己就占着那个端口——再探测会跳过它、返回下一个可用端口（9001 → 9002）。
///    消费方（`MCPClient`、用量查询）必须与服务端读到同一个值，因此解析入口
///    收敛到各 Manager 的一个缓存属性上，见 `MCPProcessManager.currentPort`。
enum PortProbe {
    /// 各服务的默认起始端口。
    enum Base {
        static let mcp = 9001
        static let tokenProxy = 8613
    }

    /// 从 `startPort` 起向后找第一个可绑定的端口，最多试 100 个。
    ///
    /// 全部占用时返回 `startPort`：让后续真正的 bind 失败并报错，
    /// 比静默返回一个「探测通过但实际不可用」的值更容易定位。
    static func detectAvailable(startingFrom startPort: Int) -> Int {
        for port in startPort ..< startPort + 100 where isAvailable(port) {
            return port
        }
        return startPort
    }

    /// 能否在本机 127.0.0.1 上 bind 该端口。只 bind 不 listen。
    static func isAvailable(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = HTTP.localHost.withCString { inet_addr($0) }

        let socketfd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketfd) }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketfd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
