import Foundation
import GRDB

/// Manages `.utility/deps.sqlite` for a specific project directory.
final class ProjectDatabase {
    /// Dependency graph database filename (single source of truth shared by Scanner/FileWatcher/AgentRunner)
    static let depsFilename = "deps.sqlite"

    let dbQueue: DatabaseQueue

    init(projectPath: String) throws {
        let utilityDir = (projectPath as NSString).appendingPathComponent(".utility")
        try FileManager.default.createDirectory(atPath: utilityDir, withIntermediateDirectories: true)
        let dbPath = (utilityDir as NSString).appendingPathComponent(Self.depsFilename)
        // Multiple connections write deps.sqlite concurrently (Scanner full scan + FileWatcher incremental + MCP reads);
        // GRDB's default busyMode=.immediateError fails immediately on lock conflict; change to .timeout(5) to wait for the lock instead of failing
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: dbPath, configuration: configuration)
        try migrator.migrate(dbQueue)
    }

    // MARK: - Schema

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "directories", ifNotExists: true) { t in
                t.column("path", .text).primaryKey()
                t.column("module_name", .text)
                t.column("parent_path", .text)
                t.column("file_count", .integer).notNull().defaults(to: 0)
                t.column("has_package_manifest", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "files", ifNotExists: true) { t in
                t.column("path", .text).primaryKey()
                t.column("dir_path", .text).notNull()
                t.column("name", .text).notNull()
                t.column("ext", .text).notNull()
                t.column("sym_count", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "symbols", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_path", .text).notNull()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("signature", .text)
                t.column("doc_comment", .text)
                t.column("visibility", .text)
            }

            try db.create(table: "packages", ifNotExists: true) { t in
                t.column("name", .text).primaryKey()
                t.column("version", .text)
                t.column("type", .text).notNull()
                t.column("description", .text)
                t.column("source_url", .text)
            }

            try db.create(table: "failed_files", ifNotExists: true) { t in
                t.column("path", .text).primaryKey()
                t.column("fail_count", .integer).notNull().defaults(to: 1)
                t.column("last_error", .text)
                t.column("last_failed_at", .text)
            }

            try db.execute(sql: """
              CREATE INDEX IF NOT EXISTS idx_files_d
              ON files(dir_path)
            """)
            try db.execute(sql: """
              CREATE INDEX IF NOT EXISTS idx_sym_f
              ON symbols(file_path)
            """)
        }

        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
              CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts
              USING fts5(name, signature, doc_comment, content=symbols, content_rowid=id)
            """)
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "symbols") { t in
                t.add(column: "start_line", .integer)
                t.add(column: "end_line", .integer)
            }
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "imports") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("from_path", .text).notNull()
                t.column("raw_target", .text).notNull()
                t.column("to_path", .text)
                t.column("is_external", .boolean).notNull().defaults(to: false)
                t.column("kind", .text).notNull()
                t.column("line", .integer)
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("resolver", .text)
            }
            try db.create(index: "idx_imports_from", on: "imports", columns: ["from_path"])
            try db.create(index: "idx_imports_to", on: "imports", columns: ["to_path"])
            try db.create(index: "idx_imports_raw", on: "imports", columns: ["raw_target"])
            // NULLs compare unequal in SQLite UNIQUE indexes; COALESCE keeps rescans idempotent.
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_imports_dedup
                ON imports(from_path, raw_target, kind,
                           COALESCE(to_path, ''), COALESCE(line, 0))
            """)
        }

        return migrator
    }

    // MARK: - Helpers

    // The clear logic is no longer exposed as a standalone method: it must be in the same transaction as the
    // writes, see `replaceScanResults`. Leaving a separately externally callable `clearAll()` would tempt later
    // developers to clear the DB at the start of a scan, reintroducing that empty window.

    /// Remove failed_files entries for files that no longer exist in the project.
    func pruneFailedFiles(knownPaths: Set<String>) throws {
        try dbQueue.write { db in
            // GRDB doesn't support NOT IN with subquery easily, use manual deletion
            let all = try String.fetchAll(db, sql: "SELECT path FROM failed_files")
            for path in all {
                if !knownPaths.contains(path) {
                    try db.execute(sql: "DELETE FROM failed_files WHERE path = ?", arguments: [path])
                }
            }
        }
    }

    func insertDirectory(_ dir: DirectoryRecord) throws {
        try dbQueue.write { db in
            try dir.insert(db, onConflict: .replace)
        }
    }

    func insertFile(_ file: FileRecord) throws {
        try dbQueue.write { db in
            try file.insert(db, onConflict: .replace)
        }
    }

    func insertSymbols(_ symbols: [SymbolRecord]) throws {
        try dbQueue.write { db in
            for s in symbols {
                try s.insert(db, onConflict: .ignore)
            }
        }
    }

    func insertPackage(_ pkg: PackageRecord) throws {
        try dbQueue.write { db in
            try pkg.insert(db, onConflict: .replace)
        }
    }

    // MARK: - failed_files

    func failedFileCount(path: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT fail_count FROM failed_files WHERE path = ?",
                arguments: [path],
            ) ?? 0
        }
    }

    func clearFailedFile(path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM failed_files WHERE path = ?", arguments: [path])
        }
    }

    // MARK: - Resolution helpers

    func allFilePaths() throws -> Set<String> {
        let paths = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM files")
        }
        return Set(paths)
    }

    /// Directories that contain any package manifest (`package.json`, `pyproject.toml`, ...).
    /// Used as Python module-root hints during incremental scans.
    func manifestDirectories() throws -> Set<String> {
        let dirs = try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT path FROM directories WHERE has_package_manifest = 1",
            )
        }
        return Set(dirs)
    }

    // MARK: - Single-file writes

    /// Replace one file's symbols, imports, file row and AST failure state in one transaction.
    func replaceFileExtraction(
        file: FileRecord,
        symbols: [SymbolRecord],
        imports: [ImportRecord],
        astFailed: Bool,
        error: String? = nil,
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM symbols WHERE file_path = ?", arguments: [file.path])
            try db.execute(sql: "DELETE FROM imports WHERE from_path = ?", arguments: [file.path])
            for symbol in symbols {
                try symbol.insert(db, onConflict: .ignore)
            }
            for imp in imports {
                try imp.insert(db, onConflict: .ignore)
            }
            try file.insert(db, onConflict: .replace)
            if astFailed {
                let message = error ?? "AST extraction failed"
                try db.execute(sql: """
                    INSERT INTO failed_files (path, fail_count, last_error, last_failed_at)
                    VALUES (?, 1, ?, datetime('now'))
                    ON CONFLICT(path) DO UPDATE SET
                        fail_count = fail_count + 1,
                        last_error = ?,
                        last_failed_at = datetime('now')
                """, arguments: [file.path, message, message])
            } else {
                try db.execute(sql: "DELETE FROM failed_files WHERE path = ?", arguments: [file.path])
            }
        }
    }

    /// Delete a file or directory subtree. Outgoing imports are removed; incoming
    /// imports keep their raw target but lose the now-stale resolved path.
    func deletePathSubtree(_ path: String) throws {
        let prefix = path + "/"
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM symbols WHERE file_path = ? OR instr(file_path, ?) = 1",
                arguments: [path, prefix],
            )
            try db.execute(
                sql: "DELETE FROM imports WHERE from_path = ? OR instr(from_path, ?) = 1",
                arguments: [path, prefix],
            )
            try db.execute(sql: """
                UPDATE imports
                SET to_path = NULL, is_external = 0, resolver = 'stale'
                WHERE to_path = ? OR instr(to_path, ?) = 1
            """, arguments: [path, prefix])
            try db.execute(
                sql: "DELETE FROM files WHERE path = ? OR instr(path, ?) = 1",
                arguments: [path, prefix],
            )
            try db.execute(
                sql: "DELETE FROM failed_files WHERE path = ? OR instr(path, ?) = 1",
                arguments: [path, prefix],
            )
            try db.execute(
                sql: "DELETE FROM directories WHERE path = ? OR instr(path, ?) = 1",
                arguments: [path, prefix],
            )
        }
    }

    // MARK: - Batch writes

    /// Atomically replace all scan results: "clear -> write -> rebuild FTS" done within a single transaction.
    ///
    /// The old flow committed `clearAll()` separately first, and only wrote back after Phase 1 traversal and Phase 2
    /// extraction (tens of seconds for large projects) finished. In that window the DB was empty to MCP readers --
    /// search tools uniformly returned empty results, the model concluded "the code does not exist", and might
    /// reimplement functionality that already exists; if the scan was interrupted (Ctrl-C, OOM, thrown error) the empty
    /// DB persisted until the next scan. After switching to a single transaction, readers see either the complete old
    /// results or the complete new results -- there is no intermediate state.
    ///
    /// Directory writes are brought in as well: previously `insertDirectory` committed separately during the empty
    /// window, leaving the DB in an inconsistent "directories present, symbols not yet" state.
    ///
    /// `failed_files` is intentionally not cleared: the 3-strike memory of consecutive AST failures must survive across
    /// scans, and entries for files that have disappeared are cleaned up by `pruneFailedFiles`.
    func replaceScanResults(
        directories: [DirectoryRecord],
        files: [(file: FileRecord, symbols: [SymbolRecord], astFailed: Bool)],
        packages: [PackageRecord],
        imports: [ImportRecord] = [],
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM directories")
            try db.execute(sql: "DELETE FROM files")
            try db.execute(sql: "DELETE FROM symbols")
            try db.execute(sql: "DELETE FROM packages")
            try db.execute(sql: "DELETE FROM imports")

            for dir in directories {
                try dir.insert(db, onConflict: .replace)
            }

            // The symbol table has been cleared entirely, so there is no need to delete row by row by file_path.
            for (fileRec, symbols, astFailed) in files {
                for s in symbols {
                    try s.insert(db, onConflict: .ignore)
                }
                try fileRec.insert(db, onConflict: .replace)
                if astFailed {
                    try db.execute(sql: """
                        INSERT INTO failed_files (path, fail_count, last_error, last_failed_at)
                        VALUES (?, 1, 'AST extraction failed', datetime('now'))
                        ON CONFLICT(path) DO UPDATE SET
                            fail_count = fail_count + 1,
                            last_error = 'AST extraction failed',
                            last_failed_at = datetime('now')
                    """, arguments: [fileRec.path])
                } else {
                    try db.execute(sql: "DELETE FROM failed_files WHERE path = ?", arguments: [fileRec.path])
                }
            }

            for pkg in packages {
                try pkg.insert(db, onConflict: .replace)
            }

            for imp in imports {
                try imp.insert(db, onConflict: .ignore)
            }

            // FTS must be rebuilt within the same transaction: symbols_fts is an external content table, and after the
            // content rows are deleted `DELETE FROM symbols_fts` extracts no terms (it is a no-op); only rebuild can align
            // the inverted index with symbols. Keeping it inside the transaction guarantees the two are consistent at commit time.
            try db.execute(sql: "INSERT INTO symbols_fts(symbols_fts) VALUES('rebuild')")
        }
    }
}

// MARK: - Records

struct DirectoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "directories"

    var path: String
    var moduleName: String?
    var parentPath: String?
    var fileCount: Int
    var hasPackageManifest: Bool

    enum CodingKeys: String, CodingKey {
        case path, moduleName = "module_name", parentPath = "parent_path",
             fileCount = "file_count", hasPackageManifest = "has_package_manifest"
    }
}

struct FileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "files"

    var path: String
    var dirPath: String
    var name: String
    var ext: String
    var symCount: Int

    enum CodingKeys: String, CodingKey {
        case path, dirPath = "dir_path", name, ext, symCount = "sym_count"
    }

    func withSymCount(_ count: Int) -> FileRecord {
        var copy = self
        copy.symCount = count
        return copy
    }
}

struct SymbolRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "symbols"

    var id: Int64?
    var filePath: String
    var name: String
    var kind: String
    var signature: String?
    var docComment: String?
    var visibility: String?
    var startLine: Int?
    var endLine: Int?

    enum CodingKeys: String, CodingKey {
        case id, filePath = "file_path", name, kind, signature,
             docComment = "doc_comment", visibility,
             startLine = "start_line", endLine = "end_line"
    }

    /// Custom init: startLine/endLine default to nil, so existing call sites (filePath:name:kind:...) compile
    /// without changes; extractors explicitly pass them in when they can compute line numbers.
    init(filePath: String, name: String, kind: String, signature: String? = nil,
         docComment: String? = nil, visibility: String? = nil,
         startLine: Int? = nil, endLine: Int? = nil)
    {
        self.filePath = filePath
        self.name = name
        self.kind = kind
        self.signature = signature
        self.docComment = docComment
        self.visibility = visibility
        self.startLine = startLine
        self.endLine = endLine
    }
}

struct PackageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "packages"

    var name: String
    var version: String?
    var type: String
    var description: String?
    var sourceUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, version, type, description, sourceUrl = "source_url"
    }
}
