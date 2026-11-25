import Cocoa

/// Delivers OSC notifications from tmux sessions that have no attached
/// SwiftTerm client, such as every workspace except the selected one.
///
/// tmux forwards OSC to attached clients only, so a detached session's
/// notification never reaches `TerminalSession.observeOscEvents`. This tap
/// mirrors pane output with `pipe-pane` and parses the OSC stream instead.
@MainActor
final class TmuxNotificationTap {
    /// Called with the tmux session id, notification title and body.
    var onNotification: ((String, String, String) -> Void)?

    private let backend = TmuxBackend()
    private var buffer: [String: [UInt8]] = [:]
    private var offset: [String: UInt64] = [:]
    private var timer: Timer?
    private let maxLogBytes: UInt64 = 4 * 1024 * 1024

    func start(id: String) {
        guard offset[id] == nil else { return }
        let path = backend.notificationLogPath(id: id)
        backend.stopNotificationTap(id: id)
        try? FileManager.default.removeItem(atPath: path)
        guard backend.startNotificationTap(id: id) else { return }
        offset[id] = 0
        buffer[id] = []
        debugLog("[Terminal] notify tap started id=\(id)")
        ensureTimer()
    }

    func stop(id: String) {
        guard offset.removeValue(forKey: id) != nil else { return }
        buffer.removeValue(forKey: id)
        backend.stopNotificationTap(id: id)
        try? FileManager.default.removeItem(atPath: backend.notificationLogPath(id: id))
        debugLog("[Terminal] notify tap stopped id=\(id)")
        if offset.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func stopAll() {
        for id in Array(offset.keys) { stop(id: id) }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pollAll() {
        for id in Array(offset.keys) { poll(id: id) }
    }

    private func poll(id: String) {
        guard let handle = FileHandle(forReadingAtPath: backend.notificationLogPath(id: id))
        else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size > maxLogBytes {
            rotate(id: id)
            return
        }
        let current = offset[id] ?? 0
        if size < current {
            offset[id] = 0
            buffer[id] = []
        }
        let start = offset[id] ?? 0
        guard size > start else { return }
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(size - start)), !data.isEmpty
            else { return }
            offset[id] = size
            var bytes = buffer[id] ?? []
            bytes.append(contentsOf: data)
            for message in TerminalNotificationParser.drain(&bytes) {
                onNotification?(id, message.title, message.body)
            }
            buffer[id] = bytes
        } catch {
            debugLog("[Terminal] notify tap read failed id=\(id): \(error)")
        }
    }

    /// The pipe keeps appending, so the log has to be reopened periodically
    /// instead of truncated in place (append offsets would create a sparse file).
    private func rotate(id: String) {
        backend.stopNotificationTap(id: id)
        try? FileManager.default.removeItem(atPath: backend.notificationLogPath(id: id))
        guard backend.startNotificationTap(id: id) else {
            stop(id: id)
            return
        }
        offset[id] = 0
        buffer[id] = []
        debugLog("[Terminal] notify tap rotated id=\(id)")
    }
}
