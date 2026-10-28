import Foundation

/// Tails a raw terminal log for OSC 9 / OSC 777 desktop notifications.
/// Screen swallows OSC before the client sees it, so the raw log is the only
/// in-session tap; see `ScreenBackend.startNotificationLog`.
final class TerminalNotificationTap {
    private static let pollInterval: TimeInterval = 0.5
    /// Screen reopens logs with O_APPEND, so truncation is safe.
    private static let maxLogBytes: UInt64 = 256 * 1024
    private static let maxPayloadBytes = 4096
    private static let maxBufferBytes = maxPayloadBytes * 2

    private let path: String
    private let queue = DispatchQueue(label: "utility.terminal.notification-tap")
    private var timer: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var buffer = Data()

    /// Called on the tap queue; hop to the main actor before touching UI.
    var onNotification: ((String, String) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            // Skip anything logged before this tap existed (old notifications).
            offset = (try? FileHandle(forReadingAtPath: path)?.seekToEnd()) ?? 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            buffer.removeAll()
            // Clear rather than delete: screen keeps the path across attaches.
            if let handle = FileHandle(forWritingAtPath: path) {
                try? handle.truncate(atOffset: 0)
                try? handle.close()
            }
            offset = 0
        }
    }

    // MARK: - Reading

    private func poll() {
        // Must be writable: truncation on a read-only handle fails, and zeroing
        // the offset then would replay the whole log on every tick.
        guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        if size > offset {
            try? handle.seek(toOffset: offset)
            let limit = Int(Self.maxLogBytes)
            if let data = try? handle.read(upToCount: limit), !data.isEmpty {
                offset += UInt64(data.count)
                consume(data)
            }
        }
        guard offset > Self.maxLogBytes else { return }
        // Only truncate when nothing arrived since the read above.
        guard (try? handle.seekToEnd()) == offset else { return }
        guard (try? handle.truncate(atOffset: 0)) != nil else { return }
        offset = 0
    }

    // MARK: - OSC parsing

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        var cursor = buffer.startIndex
        while cursor < buffer.endIndex {
            guard buffer[cursor] == 0x1B else {
                cursor += 1
                continue
            }
            guard cursor + 1 < buffer.endIndex else { break }
            guard buffer[cursor + 1] == 0x5D else {
                cursor += 1
                continue
            }
            guard let (end, terminator) = findTerminator(from: cursor + 2) else { break }
            let payload = buffer[(cursor + 2) ..< end]
            if payload.count <= Self.maxPayloadBytes {
                handle(payload)
            }
            cursor = end + terminator
        }
        // Compact once per chunk instead of shifting the tail per sequence.
        if cursor > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex ..< cursor)
        }
        if buffer.count > Self.maxBufferBytes {
            buffer.removeFirst(buffer.count - Self.maxPayloadBytes)
        }
    }

    private func findTerminator(from index: Data.Index) -> (Data.Index, Int)? {
        var cursor = index
        while cursor < buffer.endIndex {
            if buffer[cursor] == 0x07 {
                return (cursor, 1)
            }
            if buffer[cursor] == 0x1B,
               cursor + 1 < buffer.endIndex, buffer[cursor + 1] == 0x5C
            {
                return (cursor, 2)
            }
            cursor += 1
        }
        return nil
    }

    private func handle(_ payload: Data) {
        guard let text = String(data: payload, encoding: .utf8) else { return }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0] == "777", parts[1] == "notify" {
            let body = parts.count > 3 ? parts[3...].joined(separator: ";") : ""
            emit(title: parts[2], body: body)
        } else if parts.count >= 2, parts[0] == "9" {
            // `9;4;…` is a progress report, not a message.
            guard let first = parts[1].first, !first.isNumber else { return }
            emit(title: "", body: parts[1...].joined(separator: ";"))
        }
    }

    private func emit(title: String, body: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else { return }
        onNotification?(trimmedTitle, trimmedBody)
    }
}
