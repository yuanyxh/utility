import Foundation

/// Thin client for the gateway-owned project graph.
///
/// The gateway walks files, parses symbols and writes `.agent-gateway/graph.sqlite`.
/// This type only owns the resident process and forwards file events.
final class GraphScanner {
    struct Summary {
        var stats: GraphStats
        var elapsedMs: Int
    }

    let projectPath: String
    private let client: GraphIndexerClient
    private let stateLock = NSLock()
    private var stopped = false

    /// Receives the indexer PID whenever the child starts or exits.
    var onIndexerPIDChange: ((Int32) -> Void)?

    init(projectPath: String, languages: [String] = [], maxRestarts: Int = 3) throws {
        let root = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        self.projectPath = root
        let config = GraphIndexerClient.Config(root: root, maxRestarts: maxRestarts)
        client = GraphIndexerClient(config: config)
        client.onProcessChange = { [weak self] pid in
            self?.onIndexerPIDChange?(pid)
        }
    }

    deinit {
        client.stop()
    }

    func isUpToDate() throws -> Bool {
        guard let ping = client.ping(),
              ping.engineVersion == GraphProtocol.engineVersion,
              ping.schemaVersion == GraphProtocol.schemaVersion
        else { return false }
        return try client.status().upToDate == true
    }

    /// Reconciles changed and deleted files, then returns the resulting stats.
    func syncScan() throws -> Summary {
        try sync()
    }

    /// Full rebuild entry. The gateway decides between reuse and rebuild from meta.
    func fullScan() throws -> Summary {
        try sync()
    }

    func stats() throws -> GraphStats {
        try client.status().stats ?? GraphStats()
    }

    var indexerProcessIdentifier: Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return client.processIdentifier
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        client.stop()
    }

    /// Re-indexes one file. Returns false when the content hash did not change.
    @discardableResult
    func indexFile(relPath: String, force: Bool = false) throws -> Bool {
        guard !isStopped else { throw GraphScannerError.stopped }
        let response = try client.indexFile(path: relPath, force: force)
        return response.unchanged != true
    }

    func removeFile(relPath: String) throws {
        guard !isStopped else { throw GraphScannerError.stopped }
        _ = try client.removeFile(path: relPath)
    }

    private func sync() throws -> Summary {
        guard !isStopped else { throw GraphScannerError.stopped }
        let started = Date()
        let response = try client.sync()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return Summary(stats: response.stats ?? GraphStats(), elapsedMs: elapsed)
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }
}

enum GraphScannerError: LocalizedError {
    case stopped

    var errorDescription: String? {
        switch self {
        case .stopped:
            return "graph scanner stopped"
        }
    }
}
