import Foundation

/// Optional Clash (mihomo) proxy-group switcher over its Unix control socket.
/// Every failure only logs: proxy switching must never abort the digest run.
final class RSSClashSwitcher {
    private let group: String
    private let target: String
    private let stateFile: URL?
    private var socketPath: String?
    private var backup = ""

    private static let candidates = [
        NSTemporaryDirectory() + "verge-mihomo.sock",
        "/tmp/verge/verge-mihomo.sock",
    ]

    init(group: String, target: String, stateFile: URL?) {
        self.group = group
        self.target = target
        self.stateFile = stateFile
    }

    /// Restore a switch left behind by a crashed run.
    func recover() {
        guard let stateFile, FileManager.default.fileExists(atPath: stateFile.path),
              let data = try? Data(contentsOf: stateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let group = ((object["group"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let previous = ((object["previous"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !group.isEmpty, !previous.isEmpty else {
            dropState()
            return
        }
        backup = previous
        guard let path = Self.findSocket() else {
            debugLog("[RSS] clash state found but socket missing")
            return
        }
        socketPath = path
        restore(group: group)
    }

    @discardableResult
    func apply() -> Bool {
        guard let path = Self.findSocket() else {
            debugLog("[RSS] clash control socket not found, skip proxy switch")
            return false
        }
        socketPath = path
        let pathPart = "/proxies/" + (group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group)
        let (status, body) = request("GET", pathPart)
        guard status == 200,
              let object = Self.json(body), let current = object["now"] as? String,
              !current.isEmpty, current != target
        else {
            return false
        }
        backup = current
        let (switchStatus, _) = request("PUT", pathPart, body: ["name": target])
        guard switchStatus == 200 || switchStatus == 204 else {
            debugLog("[RSS] clash switch failed: HTTP \(switchStatus)")
            return false
        }
        writeState()
        debugLog("[RSS] clash group \(group): \(current) -> \(target)")
        return true
    }

    func restore() {
        restore(group: group)
    }

    // MARK: - Internal

    private func restore(group: String) {
        guard socketPath != nil, !backup.isEmpty else { return }
        let pathPart = "/proxies/" + (group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group)
        let (status, _) = request("PUT", pathPart, body: ["name": backup])
        guard status == 200 || status == 204 else {
            debugLog("[RSS] clash restore failed: HTTP \(status)")
            return
        }
        debugLog("[RSS] clash group \(group) restored to \(backup)")
        dropState()
    }

    private func writeState() {
        guard let stateFile, let data = try? JSONSerialization.data(
            withJSONObject: ["group": group, "previous": backup]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: stateFile, options: .atomic)
    }

    private func dropState() {
        guard let stateFile else { return }
        try? FileManager.default.removeItem(at: stateFile)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) -> (Int, Data) {
        guard let fd = connectSocket() else { return (0, Data()) }
        defer { close(fd) }

        var payload = Data()
        if let body, let encoded = try? JSONSerialization.data(withJSONObject: body) {
            payload = encoded
        }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if !payload.isEmpty {
            head += "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\n"
        }
        head += "\r\n"
        var message = Data(head.utf8)
        message.append(payload)
        _ = message.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            response.append(buffer, count: count)
        }

        let separator = Data("\r\n\r\n".utf8)
        guard let split = response.range(of: separator) else { return (0, Data()) }
        let header = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let bodyStart = split.upperBound
        let statusLine = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        // Go's net/http switches to chunked once the handler outgrows its sniff buffer,
        // which a proxy group with many nodes does; raw chunk framing would break JSON.
        let chunked = header.lowercased().contains("transfer-encoding: chunked")
        let rawBody = response[bodyStart...]
        return (status, chunked ? Self.decodeChunked(rawBody) : Data(rawBody))
    }

    private static func decodeChunked(_ data: Data) -> Data {
        var output = Data()
        var index = data.startIndex
        while let lineEnd = data[index...].firstIndex(of: 0x0A) {
            let sizeLine = String(decoding: data[index ..< lineEnd], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let sizeText = sizeLine.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16), size > 0 else { break }
            let start = data.index(after: lineEnd)
            let end = min(start + size, data.endIndex)
            output.append(data[start ..< end])
            var next = end
            while next < data.endIndex, data[next] == 0x0D || data[next] == 0x0A {
                next += 1
            }
            index = next
        }
        return output
    }

    private func connectSocket() -> Int32? {
        guard let path = socketPath else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func findSocket() -> String? {
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let probe = RSSClashSwitcher(group: "", target: "", stateFile: nil)
            probe.socketPath = path
            let (status, _) = probe.request("GET", "/version")
            if status == 200 { return path }
        }
        return nil
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
