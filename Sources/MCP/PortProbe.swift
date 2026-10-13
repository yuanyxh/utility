import Foundation

/// Local port probing — a resident service picks an available port when its
/// configured port is 0 (auto-detect).
///
/// It exists as its own utility for two reasons:
///
/// 1. This logic was previously duplicated verbatim across `MCPProcessManager`
///    and `TokenProxyManager` (37 lines, differing only in a start-port constant).
/// 2. The port **must be resolved exactly once and cached**. Probing works by a
///    bind test, and once the service is up it already holds that port — probing
///    again skips it and returns the next free port (9001 → 9002). Consumers
///    (`MCPClient`, usage queries) must read the same value as the server, so
///    resolution is funneled into a cached property on each Manager; see
///    `MCPProcessManager.currentPort`.
enum PortProbe {
    /// Default start port for each service.
    enum Base {
        static let mcp = 9001
        static let tokenProxy = 8613
    }

    /// Finds the first bindable port at or after `startPort`, trying up to 100.
    ///
    /// Returns `startPort` when all are taken: letting the real bind fail and
    /// report an error is easier to diagnose than silently returning a value
    /// that "passed probing" but is not actually usable.
    static func detectAvailable(startingFrom startPort: Int) -> Int {
        for port in startPort ..< startPort + 100 where isAvailable(port) {
            return port
        }
        return startPort
    }

    /// Whether the port can be bound on local 127.0.0.1. Binds without listening.
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
