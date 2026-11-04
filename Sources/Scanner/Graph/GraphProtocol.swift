import CryptoKit
import Foundation

/// Version identity written into `graph.sqlite` meta. Bumping either forces a full rebuild.
enum GraphProtocol {
    static let engineVersion = "2"
    static let schemaVersion = "1"

    /// Phase 1 adapters implemented by the gateway. Empty `graph.languages` resolves to this set.
    static let defaultLanguages: Set<String> = [
        "swift", "python", "typescript", "javascript", "vue", "java", "kotlin", "objc",
    ]

    /// Extension to language name; shared by full scans and incremental updates.
    static let languagesByExtension: [String: String] = [
        "swift": "swift",
        "py": "python",
        "ts": "typescript",
        "tsx": "typescript",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "vue": "vue",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "m": "objc",
        "h": "objc",
    ]

    static func language(forExtension ext: String) -> String? {
        languagesByExtension[ext.lowercased()]
    }
}

// MARK: - Indexer protocol (JSON Lines)

/// Request sent to the resident `graphIndexer` service.
struct GraphIndexRequest: Codable {
    enum Op: String, Codable {
        case indexFile = "index_file"
        case indexBatch = "index_batch"
        case prepare
        case removeFile = "remove_file"
        case ping
        case sync
        case status
    }

    var op: Op
    var root: String?
    var path: String?
    var contentHash: String?
    var lang: String?
    var files: [GraphBatchFile]?
    var paths: [String]?
    var force: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case op, root, path, lang, files, paths, force
        case contentHash = "content_hash"
    }
}


struct GraphBatchFile: Codable {
    var path: String
    var contentHash: String
    var lang: String

    enum CodingKeys: String, CodingKey {
        case path, lang
        case contentHash = "content_hash"
    }
}

/// One per-file parse result. `ok == false` must never carry partial symbols or edges.
struct GraphIndexResponse: Codable {
    var ok: Bool = true
    var path: String?
    var symbols: [GraphRawSymbol] = []
    var edges: [GraphRawEdge] = []
    var unresolved: [GraphRawUnresolved] = []
    var error: String?
    var reason: String?
    var engineVersion: String?
    var schemaVersion: String?
    var stats: GraphStats?
    var dbPath: String?
    var upToDate: Bool?
    var unchanged: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, path, symbols, edges, unresolved, error, reason, stats, unchanged
        case engineVersion = "engine_version"
        case schemaVersion = "schema_version"
        case dbPath = "db_path"
        case upToDate = "up_to_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        path = try c.decodeIfPresent(String.self, forKey: .path)
        symbols = try c.decodeIfPresent([GraphRawSymbol].self, forKey: .symbols) ?? []
        edges = try c.decodeIfPresent([GraphRawEdge].self, forKey: .edges) ?? []
        unresolved = try c.decodeIfPresent([GraphRawUnresolved].self, forKey: .unresolved) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        engineVersion = try c.decodeIfPresent(String.self, forKey: .engineVersion)
        schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion)
        stats = try c.decodeIfPresent(GraphStats.self, forKey: .stats)
        dbPath = try c.decodeIfPresent(String.self, forKey: .dbPath)
        upToDate = try c.decodeIfPresent(Bool.self, forKey: .upToDate)
        unchanged = try c.decodeIfPresent(Bool.self, forKey: .unchanged)
    }
}

struct GraphRawSymbol: Codable {
    var name: String
    var kind: String
    var signature: String?
    var startLine: Int
    var endLine: Int

    enum CodingKeys: String, CodingKey {
        case name, kind, signature
        case startLine = "start_line"
        case endLine = "end_line"
    }
}

struct GraphRawEdge: Codable {
    var fromName: String?
    var fromLine: Int?
    var rawName: String
    var kind: String
    var line: Int?
    var confidence: Double
    var resolver: String

    /// Optional resolved target. The base contract may omit it; the host then resolves by name.
    var toKey: String?
    var toPath: String?
    var toName: String?
    var toKind: String?
    var toSignature: String?

    enum CodingKeys: String, CodingKey {
        case kind, line, confidence, resolver
        case fromName = "from_name"
        case fromLine = "from_line"
        case rawName = "raw_name"
        case toKey = "to_key"
        case toPath = "to_path"
        case toName = "to_name"
        case toKind = "to_kind"
        case toSignature = "to_signature"
    }
}

struct GraphRawUnresolved: Codable {
    var rawName: String
    var kind: String
    var line: Int?
    var reason: String

    enum CodingKeys: String, CodingKey {
        case kind, line, reason
        case rawName = "raw_name"
    }
}

// MARK: - Node keys

enum GraphKey {
    static func file(_ path: String) -> String {
        "file:" + path
    }

    static func symbol(_ symKey: String) -> String {
        "sym:" + symKey
    }

    /// Content-addressed symbol identity, including start line to keep overloads unique.
    static func symbolKey(
        path: String,
        name: String,
        kind: String,
        signature: String?,
        startLine: Int
    ) -> String {
        sha1Hex("\(path)|\(name)|\(kind)|\(signature ?? "")|\(startLine)")
    }

    static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Query results

struct GraphStats: Codable {
    var nodes: Int = 0
    var edges: Int = 0
    var stale: Int = 0
    var files: Int = 0
    var symbols: Int = 0
    var unresolved: Int = 0
}

// MARK: - Logging

/// Structured JSONL log at `~/Library/Logs/Utility/graph.log`.
enum GraphLog {
    static let path: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Utility")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("graph.log").path
    }()

    private static let lock = NSLock()

    static func log(
        traceID: String,
        op: String,
        project: String,
        file: String? = nil,
        elapsedMs: Int,
        edgeCount: Int,
        unresolvedCount: Int
    ) {
        var payload: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "trace_id": traceID,
            "op": op,
            "project": project,
            "elapsed_ms": elapsedMs,
            "edge_count": edgeCount,
            "unresolved_count": unresolvedCount,
        ]
        if let file { payload["file"] = file }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"

        lock.lock()
        defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    static func traceID(prefix: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: "[-:]", with: "", options: .regularExpression)
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(prefix)_\(stamp)_\(suffix)"
    }
}
