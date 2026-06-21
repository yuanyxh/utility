import Darwin
import Foundation

/// 每 3 秒轮询 enX 网卡流量，计算上行/下行速度
final class NetworkSpeedMonitor {
    static let shared = NetworkSpeedMonitor()

    private var timer: DispatchSourceTimer?
    private var previous: (rx: UInt64, tx: UInt64)?
    private let queue = DispatchQueue(label: "utility.network-monitor", qos: .utility)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        timer = t
        debugLog("[Network] Monitoring started")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        previous = nil
        debugLog("[Network] Monitoring stopped")
    }

    // MARK: - Poll

    private func poll() {
        guard let current = interfaceBytes() else { return }
        defer { previous = current }

        guard let prev = previous else { return }

        let down = current.rx > prev.rx ? current.rx - prev.rx : 0
        let up = current.tx > prev.tx ? current.tx - prev.tx : 0

        let upText = format(up)
        let downText = format(down)
        DispatchQueue.main.async {
            EventBus.shared.publish(AppEvent.networkSpeedUpdated, payload: (upText, downText))
        }
    }

    // MARK: - Formatting

    /// ≥1GB → X.XXG, else → X.XXM
    private func format(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.2fG", Double(bytes) / 1_000_000_000.0)
        } else {
            return String(format: "%.2fM", Double(bytes) / 1_000_000.0)
        }
    }

    // MARK: - getifaddrs

    /// 汇总所有 enX (en0, en1, ...) 的 ifi_ibytes / ifi_obytes
    private func interfaceBytes() -> (rx: UInt64, tx: UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en"), name.dropFirst(2).allSatisfy({ $0.isNumber }) else { continue }

            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_LINK), let data = ptr.pointee.ifa_data else { continue }

            let ifd = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(ifd.ifi_ibytes)
            tx += UInt64(ifd.ifi_obytes)
        }

        return (rx, tx)
    }
}
