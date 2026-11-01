import Foundation

/// Client for the resident `graphIndexer` gateway module.
///
/// The process speaks JSON Lines on stdin/stdout. Lifecycle mirrors `PythonDaemon`:
/// lazy launch, timeout, crash restart with a bounded retry count, and error propagation.
final class GraphIndexerClient {
    struct Config {
        var root: String
        var maxRestarts = 3
        var requestTimeout: TimeInterval = 30
        var batchTimeout: TimeInterval = 180
    }

    /// Stderr tail included in propagated errors; kept small on purpose.
    private static let stderrLimit = 8 * 1024

    private let config: Config
    private let ioQueue = DispatchQueue(label: "com.utility.graph-indexer")
    private let bufferLock = NSLock()
    private let responseSignal = DispatchSemaphore(value: 0)

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readBuffer = Data()
    private var stderrBuffer = Data()
    private var reachedEOF = false
    private var isStopping = false
    private let stopLock = NSLock()
    private var stopRequested = false

    /// PID of the resident process; 0 when none is running.
    var onProcessChange: ((Int32) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(config: Config) {
        self.config = config
    }

    deinit {
        stop()
    }

    /// PID of the current child; read from signal context, so it takes no locks.
    var processIdentifier: Int32? {
        process?.processIdentifier
    }

    // MARK: - Public operations

    func indexFile(path: String, contentHash: String, lang: String) throws -> GraphIndexResponse {
        let request = GraphIndexRequest(
            op: .indexFile,
            root: config.root,
            path: path,
            contentHash: contentHash,
            lang: lang,
            files: nil,
            paths: nil,
        )
        let responses = try perform(request, expected: 1, timeout: config.requestTimeout)
        guard let first = responses.first else {
            throw GraphIndexerError.protocolViolation("empty response for \(path)")
        }
        guard first.ok else {
            throw GraphIndexerError.protocolViolation(
                first.error ?? first.reason ?? "index_file failed for \(path)",
            )
        }
        if let responsePath = first.path, responsePath != path {
            throw GraphIndexerError.protocolViolation(
                "response path \(responsePath) != \(path)",
            )
        }
        return first
    }

    /// Replaces the indexer's in-memory file set with the host's current set.
    func prepare(paths: [String]) throws -> GraphIndexResponse {
        let request = GraphIndexRequest(
            op: .prepare,
            root: config.root,
            path: nil,
            contentHash: nil,
            lang: nil,
            files: nil,
            paths: paths,
        )
        let responses = try perform(request, expected: 1, timeout: config.batchTimeout)
        guard let first = responses.first, first.ok else {
            throw GraphIndexerError.protocolViolation("prepare failed")
        }
        return first
    }

    func removeFile(path: String) throws -> GraphIndexResponse {
        let request = GraphIndexRequest(
            op: .removeFile,
            root: config.root,
            path: path,
            contentHash: nil,
            lang: nil,
            files: nil,
            paths: nil,
        )
        let responses = try perform(request, expected: 1, timeout: config.requestTimeout)
        guard let first = responses.first, first.ok else {
            throw GraphIndexerError.protocolViolation(
                "remove_file failed for \(path)",
            )
        }
        return first
    }

    func indexBatch(files: [GraphBatchFile], timeout: TimeInterval? = nil) throws -> [GraphIndexResponse] {
        guard !files.isEmpty else { return [] }
        let request = GraphIndexRequest(
            op: .indexBatch,
            root: config.root,
            path: nil,
            contentHash: nil,
            lang: nil,
            files: files,
            paths: nil,
        )
        return try perform(
            request,
            expected: files.count,
            timeout: timeout ?? config.batchTimeout,
        )
    }

    func ping() -> GraphIndexResponse? {
        let request = GraphIndexRequest(
            op: .ping,
            root: nil,
            path: nil,
            contentHash: nil,
            lang: nil,
            files: nil,
            paths: nil,
        )
        return (try? perform(request, expected: 1, timeout: 10))?.first
    }

    func stop() {
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
        // Wake a blocked read immediately; Process.terminate is thread-safe.
        process?.terminate()
        ioQueue.sync {
            isStopping = true
            terminateProcess()
        }
    }

    private var isStopRequested: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    // MARK: - Request loop

    private func perform(
        _ request: GraphIndexRequest,
        expected: Int,
        timeout: TimeInterval
    ) throws -> [GraphIndexResponse] {
        try ioQueue.sync {
            var attempt = 0
            while true {
                if isStopRequested || isStopping {
                    throw GraphIndexerError.stopped
                }
                try ensureRunning()
                do {
                    return try exchange(request, expected: expected, timeout: timeout)
                } catch {
                    terminateProcess()
                    attempt += 1
                    let summary = "op=\(request.op.rawValue) attempt=\(attempt) "
                        + "error=\(error.localizedDescription)"
                    debugLog("[GraphIndexer] \(summary)")
                    if isStopping || attempt > config.maxRestarts {
                        throw error
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
    }

    private func exchange(
        _ request: GraphIndexRequest,
        expected: Int,
        timeout: TimeInterval
    ) throws -> [GraphIndexResponse] {
        guard let proc = process, proc.isRunning, let input = inputPipe else {
            throw GraphIndexerError.notRunning
        }
        let traceID = GraphLog.traceID(prefix: "gi")
        let started = Date()

        bufferLock.lock()
        readBuffer.removeAll(keepingCapacity: true)
        reachedEOF = false
        bufferLock.unlock()

        var payload = try encoder.encode(request)
        payload.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: payload)
            debugLog("[GraphIndexer] sent \(payload.count) bytes expected \(expected)")
        } catch {
            throw GraphIndexerError.writeFailed(error.localizedDescription)
        }

        var responses: [GraphIndexResponse] = []
        while responses.count < expected {
            let line = try readLine(timeout: timeout)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let batch = try decodeBatchEnvelope(line) {
                responses.append(contentsOf: batch)
                break
            }
            responses.append(try decodeResponse(line))
        }
        if responses.count != expected {
            throw GraphIndexerError.protocolViolation(
                "expected \(expected) responses, got \(responses.count)",
            )
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let edgeCount = responses.reduce(0) { $0 + $1.edges.count }
        let unresolvedCount = responses.reduce(0) { $0 + $1.unresolved.count }
        let file = request.path ?? request.files?.first?.path
        GraphLog.log(
            traceID: traceID,
            op: request.op.rawValue,
            project: config.root,
            file: file,
            elapsedMs: elapsed,
            edgeCount: edgeCount,
            unresolvedCount: unresolvedCount,
        )
        return responses
    }

    /// Reads one newline-terminated JSON line, bounded by `timeout`.
    private func readLine(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            bufferLock.lock()
            if let index = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: index)
                readBuffer.removeSubrange(0 ... index)
                bufferLock.unlock()
                return String(decoding: line, as: UTF8.self)
            }
            let eof = reachedEOF
            bufferLock.unlock()

            if eof {
                throw GraphIndexerError.processExited(status: process?.terminationStatus, stderr: stderrText())
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw GraphIndexerError.timeout(seconds: timeout)
            }
            _ = responseSignal.wait(timeout: .now() + remaining)
        }
    }

    private func decodeResponse(_ line: String) throws -> GraphIndexResponse {
        guard let data = line.data(using: .utf8) else {
            throw GraphIndexerError.protocolViolation("non-UTF8 line")
        }
        do {
            return try decoder.decode(GraphIndexResponse.self, from: data)
        } catch {
            throw GraphIndexerError.protocolViolation(
                "decode failed: \(error.localizedDescription); line=\(line.prefix(200))",
            )
        }
    }

    /// Accepts an optional wrapper (`{"files":[...]}` / `{"results":[...]}`) or a bare array.
    private func decodeBatchEnvelope(_ line: String) throws -> [GraphIndexResponse]? {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        if let array = parsed as? [Any] {
            let payload = try JSONSerialization.data(withJSONObject: array)
            return try decoder.decode([GraphIndexResponse].self, from: payload)
        }
        guard let object = parsed as? [String: Any] else { return nil }
        let array: [Any]?
        if let files = object["files"] as? [Any] {
            array = files
        } else if let results = object["results"] as? [Any] {
            array = results
        } else {
            array = nil
        }
        guard let array else { return nil }
        guard let payload = try? JSONSerialization.data(withJSONObject: array) else {
            throw GraphIndexerError.protocolViolation("invalid batch payload")
        }
        return try decoder.decode([GraphIndexResponse].self, from: payload)
    }

    // MARK: - Process lifecycle

    private func ensureRunning() throws {
        if let proc = process, proc.isRunning { return }
        terminateProcess()
        try launch()
    }

    private func launch() throws {
        guard let python = PythonScriptRunner.resolvePython() else {
            throw GraphIndexerError.pythonUnavailable
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = PythonScriptRunner.bootstrapArguments(for: GatewayEntry.graphIndexer)
        proc.environment = PythonScriptRunner.environment(overrides: [:])

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = error

        bufferLock.lock()
        readBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)
        reachedEOF = false
        bufferLock.unlock()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            debugLog("[GraphIndexer] read \(chunk.count) bytes")
            self.bufferLock.lock()
            if chunk.isEmpty {
                self.reachedEOF = true
                self.onProcessChange?(0)
            } else {
                self.readBuffer.append(chunk)
            }
            self.bufferLock.unlock()
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self.responseSignal.signal()
        }

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.bufferLock.lock()
            self.stderrBuffer.append(chunk)
            if self.stderrBuffer.count > Self.stderrLimit {
                self.stderrBuffer = Data(self.stderrBuffer.suffix(Self.stderrLimit))
            }
            self.bufferLock.unlock()
        }

        do {
            try proc.run()
        } catch {
            throw GraphIndexerError.launchFailed(error.localizedDescription)
        }

        inputPipe = input
        outputPipe = output
        errorPipe = error
        process = proc
        onProcessChange?(proc.processIdentifier)
        debugLog("[GraphIndexer] Started (PID \(proc.processIdentifier))")
    }

    private func terminateProcess() {
        guard let proc = process else { return }
        process = nil

        inputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        if proc.isRunning {
            proc.terminate()
            let deadline = DispatchTime.now() + 2.0
            while proc.isRunning, .now() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        onProcessChange?(0)
    }

    private func stderrText() -> String {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }
}

enum GraphIndexerError: LocalizedError {
    case pythonUnavailable
    case launchFailed(String)
    case notRunning
    case writeFailed(String)
    case timeout(seconds: TimeInterval)
    case processExited(status: Int32?, stderr: String)
    case protocolViolation(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            return "No usable Python for graphIndexer"
        case let .launchFailed(message):
            return "graphIndexer launch failed: \(message)"
        case .notRunning:
            return "graphIndexer is not running"
        case let .writeFailed(message):
            return "graphIndexer write failed: \(message)"
        case let .timeout(seconds):
            return "graphIndexer timed out after \(Int(seconds))s"
        case let .processExited(status, stderr):
            let code = status.map(String.init) ?? "unknown"
            let tail = stderr.isEmpty ? "" : "; stderr=\(stderr.suffix(500))"
            return "graphIndexer exited (status \(code))\(tail)"
        case let .protocolViolation(message):
            return "graphIndexer protocol error: \(message)"
        case .stopped:
            return "graphIndexer client stopped"
        }
    }
}
