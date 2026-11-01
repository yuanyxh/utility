import Foundation
import GRDB

/// Owns `.utility/graph.sqlite`: schema, atomic full replacement, incremental writes and queries.
///
/// The graph is independent from the legacy `.utility/deps.sqlite`; neither side reads the other.
final class GraphDatabase {
    static let graphFilename = "graph.sqlite"

    struct FileRow {
        var path: String
        var lang: String
        var size: Int
        var mtime: Double
        var contentHash: String
    }

    struct FileMeta {
        var path: String
        var size: Int
        var mtime: Double
        var contentHash: String
    }

    struct SymbolRow {
        var symKey: String
        var path: String
        var name: String
        var kind: String
        var signature: String?
        var startLine: Int
        var endLine: Int
    }

    struct EdgeRow {
        var fromKey: String
        var toKey: String
        var kind: String
        var path: String
        var startLine: Int?
        var endLine: Int?
        var confidence: Double
        var resolver: String
        var status: String
    }

    struct UnresolvedRow {
        var path: String
        var rawName: String
        var kind: String
        var line: Int?
        var reason: String
    }

    let dbQueue: DatabaseQueue

    static func databasePath(projectPath: String) -> String {
        let utilityDir = (projectPath as NSString).appendingPathComponent(".utility")
        return (utilityDir as NSString).appendingPathComponent(graphFilename)
    }

    init(projectPath: String) throws {
        let utilityDir = (projectPath as NSString).appendingPathComponent(".utility")
        try FileManager.default.createDirectory(atPath: utilityDir, withIntermediateDirectories: true)
        dbQueue = try SQLiteFactory.open(path: Self.databasePath(projectPath: projectPath), journal: .wal)
        try migrator.migrate(dbQueue)
    }

    // MARK: - Schema

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("graph-v1") { db in
            try db.create(table: "meta", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            try db.create(table: "files", ifNotExists: true) { t in
                t.column("path", .text).primaryKey()
                t.column("lang", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("content_hash", .text).notNull()
            }
            try db.create(table: "symbols", ifNotExists: true) { t in
                t.column("sym_key", .text).primaryKey()
                t.column("path", .text).notNull()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("signature", .text)
                t.column("start_line", .integer).notNull()
                t.column("end_line", .integer).notNull()
            }
            try db.create(index: "idx_symbols_name", on: "symbols", columns: ["name"])
            try db.create(index: "idx_symbols_path", on: "symbols", columns: ["path"])

            try db.create(table: "edges", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("from_key", .text).notNull()
                t.column("to_key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull()
                t.column("start_line", .integer)
                t.column("end_line", .integer)
                t.column("confidence", .double).notNull()
                t.column("resolver", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "ok")
            }
            try db.create(index: "idx_edges_to", on: "edges", columns: ["to_key", "kind"])
            try db.create(index: "idx_edges_from", on: "edges", columns: ["from_key", "kind"])
            try db.create(index: "idx_edges_path", on: "edges", columns: ["path"])

            try db.create(table: "unresolved", ifNotExists: true) { t in
                t.column("path", .text).notNull()
                t.column("raw_name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("line", .integer)
                t.column("reason", .text).notNull()
            }
            try db.create(index: "idx_unresolved_name", on: "unresolved", columns: ["raw_name"])

            try db.create(table: "diagnostics", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        return migrator
    }

    // MARK: - Meta

    func meta() throws -> [String: String] {
        try dbQueue.read { db in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM meta") {
                result[row["key"]] = row["value"]
            }
            return result
        }
    }

    /// True only when engine, schema and project root all match the stored meta.
    func isUpToDate(root: String) throws -> Bool {
        let stored = try meta()
        return stored["engine_version"] == GraphProtocol.engineVersion
            && stored["schema_version"] == GraphProtocol.schemaVersion
            && stored["root"] == root
    }

    func fileHash(path: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT content_hash FROM files WHERE path = ?",
                arguments: [path],
            )
        }
    }

    /// Files whose unresolved references mention any of these names.
    func unresolvedPaths(named names: Set<String>) throws -> Set<String> {
        guard !names.isEmpty else { return [] }
        let list = Array(names)
        var result = Set<String>()
        try dbQueue.read { db in
            var offset = 0
            while offset < list.count {
                let chunk = Array(list[offset ..< min(offset + 500, list.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let paths = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT path FROM unresolved WHERE raw_name IN (\(placeholders))",
                    arguments: StatementArguments(chunk),
                )
                result.formUnion(paths)
                offset += 500
            }
        }
        return result
    }

    /// Metadata for every indexed file; used to skip unchanged files without reading them.
    func allFileMeta() throws -> [String: FileMeta] {
        try dbQueue.read { db in
            var result: [String: FileMeta] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT path, size, mtime, content_hash FROM files",
            ) {
                let path: String = row["path"]
                result[path] = FileMeta(
                    path: path,
                    size: row["size"],
                    mtime: row["mtime"],
                    contentHash: row["content_hash"],
                )
            }
            return result
        }
    }

    /// Refreshes stat-only changes so a touched file is not re-read on every startup.
    func updateFileMeta(path: String, size: Int, mtime: Double) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE files SET size = ?, mtime = ? WHERE path = ?",
                arguments: [size, mtime, path],
            )
        }
    }

    func recordDiagnostic(key: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO diagnostics (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value],
            )
        }
    }

    /// Reclaims stale edges whose target symbol or file no longer exists.
    func deleteDanglingStaleEdges() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM edges
                WHERE status = 'stale'
                  AND to_key NOT IN (SELECT 'sym:' || sym_key FROM symbols)
                  AND to_key NOT IN (SELECT 'file:' || path FROM files)
                """,
            )
        }
    }

    // MARK: - Atomic full replacement

    /// Replaces the whole graph in one transaction; readers never observe an empty database.
    func replaceGraph(
        meta: [String: String],
        files: [FileRow],
        symbols: [SymbolRow],
        edges: [EdgeRow],
        unresolved: [UnresolvedRow],
        diagnostics: [String: String]
    ) throws {
        try dbQueue.write { db in
            for table in ["edges", "symbols", "files", "unresolved", "diagnostics", "meta"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for (key, value) in meta {
                try db.execute(
                    sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
                    arguments: [key, value],
                )
            }
            for file in files {
                try db.execute(
                    sql: """
                    INSERT INTO files (path, lang, size, mtime, content_hash)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [file.path, file.lang, file.size, file.mtime, file.contentHash],
                )
            }
            for symbol in symbols {
                try GraphDatabase.insertSymbol(db, symbol)
            }
            for edge in edges {
                try GraphDatabase.insertEdge(db, edge)
            }
            for item in unresolved {
                try GraphDatabase.insertUnresolved(db, item)
            }
            for (key, value) in diagnostics {
                try db.execute(
                    sql: "INSERT INTO diagnostics (key, value) VALUES (?, ?)",
                    arguments: [key, value],
                )
            }
        }
    }

    // MARK: - Incremental writes

    /// Replaces one file's symbols/out-edges and marks incoming edges to removed symbols stale.
    func replaceFile(
        file: FileRow,
        symbols: [SymbolRow],
        edges: [EdgeRow],
        unresolved: [UnresolvedRow]
    ) throws {
        try dbQueue.write { db in
            let oldSymbols = try Row.fetchAll(
                db,
                sql: "SELECT sym_key, name, kind, signature FROM symbols WHERE path = ?",
                arguments: [file.path],
            )
            let oldKeys = oldSymbols.map { $0["sym_key"] as String }
            try db.execute(sql: "DELETE FROM symbols WHERE path = ?", arguments: [file.path])
            try db.execute(sql: "DELETE FROM edges WHERE path = ?", arguments: [file.path])
            try db.execute(sql: "DELETE FROM unresolved WHERE path = ?", arguments: [file.path])
            try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [file.path])

            try db.execute(
                sql: """
                INSERT INTO files (path, lang, size, mtime, content_hash)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [file.path, file.lang, file.size, file.mtime, file.contentHash],
            )
            for symbol in symbols {
                try GraphDatabase.insertSymbol(db, symbol)
            }
            for edge in edges {
                try GraphDatabase.insertEdge(db, edge)
            }
            for item in unresolved {
                try GraphDatabase.insertUnresolved(db, item)
            }

            let newKeys = Set(symbols.map(\.symKey))
            let oldKeySet = Set(oldKeys)
            var rebound = Set<String>()
            for old in oldSymbols {
                let oldKey: String = old["sym_key"]
                if newKeys.contains(oldKey) { continue }
                let name: String = old["name"]
                let kind: String = old["kind"]
                let signature: String? = old["signature"]
                guard let match = symbols.first(where: {
                    !oldKeySet.contains($0.symKey)
                        && $0.name == name && $0.kind == kind
                        && $0.signature == signature
                        && !rebound.contains($0.symKey)
                }) else { continue }
                rebound.insert(match.symKey)
                // A line shift changes sym_key; keep incoming edges alive instead
                // of leaving them stale with no recovery path.
                try db.execute(
                    sql: "UPDATE edges SET to_key = ?, status = 'ok' WHERE to_key = ?",
                    arguments: [GraphKey.symbol(match.symKey), GraphKey.symbol(oldKey)],
                )
            }
            // A recreated file revives import edges that were marked stale on delete.
            try db.execute(
                sql: """
                UPDATE edges SET status = 'ok'
                WHERE to_key = ? AND status = 'stale'
                """,
                arguments: [GraphKey.file(file.path)],
            )
            let removed = oldKeys.filter { !newKeys.contains($0) }
            try GraphDatabase.markIncomingStale(db, oldKeys: removed)
        }
    }

    /// Removes a file, or every file under a directory; incoming edges become stale.
    func deletePathSubtree(path: String) throws {
        try dbQueue.write { db in
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let paths = try String.fetchAll(
                db,
                sql: """
                SELECT path FROM files
                WHERE path = ? OR path LIKE ? ESCAPE '\\'
                """,
                arguments: [path, GraphDatabase.likeEscaped(prefix) + "%"],
            )
            var oldKeys: [String] = []
            for filePath in paths {
                oldKeys.append(contentsOf: try String.fetchAll(
                    db,
                    sql: "SELECT sym_key FROM symbols WHERE path = ?",
                    arguments: [filePath],
                ))
                try db.execute(sql: "DELETE FROM symbols WHERE path = ?", arguments: [filePath])
                try db.execute(sql: "DELETE FROM edges WHERE path = ?", arguments: [filePath])
                try db.execute(sql: "DELETE FROM unresolved WHERE path = ?", arguments: [filePath])
                try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [filePath])
            }
            for start in stride(from: 0, to: oldKeys.count, by: 500) {
                let end = min(start + 500, oldKeys.count)
                try GraphDatabase.markIncomingStale(
                    db, oldKeys: Array(oldKeys[start ..< end]))
            }
            let fileKeys = paths.map(GraphKey.file)
            for start in stride(from: 0, to: fileKeys.count, by: 500) {
                let end = min(start + 500, fileKeys.count)
                try GraphDatabase.markNodeStale(
                    db, nodeKeys: Array(fileKeys[start ..< end]))
            }
        }
    }

    private static func likeEscaped(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: - Stats

    func stats() throws -> GraphStats {
        try dbQueue.read { db in
            let files = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
            let symbols = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM symbols") ?? 0
            let edges = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges") ?? 0
            let stale = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM edges WHERE status = 'stale'",
            ) ?? 0
            let unresolved = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM unresolved") ?? 0
            return GraphStats(
                nodes: files + symbols,
                edges: edges,
                stale: stale,
                files: files,
                symbols: symbols,
                unresolved: unresolved,
            )
        }
    }

    // MARK: - Symbol lookup helpers

    /// All symbols whose name is in `names`; used to resolve incremental edges.
    func symbols(named names: [String]) throws -> [SymbolRow] {
        guard !names.isEmpty else { return [] }
        return try dbQueue.read { db in
            var result: [SymbolRow] = []
            var offset = 0
            while offset < names.count {
                let chunk = Array(names[offset ..< min(offset + 500, names.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let sql = """
                SELECT sym_key, path, name, kind, signature, start_line, end_line
                FROM symbols WHERE name IN (\(placeholders))
                """
                let rows = try Row.fetchAll(
                    db, sql: sql, arguments: StatementArguments(chunk))
                result.append(contentsOf: rows.map(GraphDatabase.symbolRow(from:)))
                offset += 500
            }
            return result
        }
    }

    // MARK: - Lookup

    // MARK: - Impact

    // MARK: - Internal helpers

    private static func insertSymbol(_ db: Database, _ symbol: SymbolRow) throws {
        try db.execute(
            sql: """
            INSERT INTO symbols (sym_key, path, name, kind, signature, start_line, end_line)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                symbol.symKey, symbol.path, symbol.name, symbol.kind,
                symbol.signature, symbol.startLine, symbol.endLine,
            ],
        )
    }

    private static func insertEdge(_ db: Database, _ edge: EdgeRow) throws {
        try db.execute(
            sql: """
            INSERT INTO edges
              (from_key, to_key, kind, path, start_line, end_line,
               confidence, resolver, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                edge.fromKey, edge.toKey, edge.kind, edge.path,
                edge.startLine, edge.endLine, edge.confidence,
                edge.resolver, edge.status,
            ],
        )
    }

    private static func insertUnresolved(_ db: Database, _ item: UnresolvedRow) throws {
        try db.execute(
            sql: "INSERT INTO unresolved (path, raw_name, kind, line, reason) VALUES (?, ?, ?, ?, ?)",
            arguments: [item.path, item.rawName, item.kind, item.line, item.reason],
        )
    }

    private static func markNodeStale(_ db: Database, nodeKeys: [String]) throws {
        guard !nodeKeys.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: nodeKeys.count)
            .joined(separator: ",")
        try db.execute(
            sql: """
            UPDATE edges SET status = 'stale'
            WHERE to_key IN (\(placeholders)) AND status = 'ok'
            """,
            arguments: StatementArguments(nodeKeys),
        )
    }

    private static func markIncomingStale(_ db: Database, oldKeys: [String]) throws {
        guard !oldKeys.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: oldKeys.count).joined(separator: ",")
        let targetKeys = oldKeys.map { GraphKey.symbol($0) }
        try db.execute(
            sql: """
            UPDATE edges SET status = 'stale'
            WHERE to_key IN (\(placeholders)) AND status = 'ok'
            """,
            arguments: StatementArguments(targetKeys),
        )
    }

    private static func symbolRow(from row: Row) -> SymbolRow {
        SymbolRow(
            symKey: row["sym_key"],
            path: row["path"],
            name: row["name"],
            kind: row["kind"],
            signature: row["signature"],
            startLine: row["start_line"],
            endLine: row["end_line"],
        )
    }

}
