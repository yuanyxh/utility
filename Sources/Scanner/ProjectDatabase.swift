import Foundation
import GRDB

/// Manages `.utility/deps.sqlite` for a specific project directory.
final class ProjectDatabase {
    let dbQueue: DatabaseQueue

    init(projectPath: String) throws {
        let utilityDir = (projectPath as NSString).appendingPathComponent(".utility")
        try FileManager.default.createDirectory(atPath: utilityDir, withIntermediateDirectories: true)
        let dbPath = (utilityDir as NSString).appendingPathComponent("deps.sqlite")
        dbQueue = try DatabaseQueue(path: dbPath)
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

        return migrator
    }

    // MARK: - Helpers

    func clearAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM directories")
            try db.execute(sql: "DELETE FROM files")
            try db.execute(sql: "DELETE FROM symbols")
            try db.execute(sql: "DELETE FROM packages")
            // Keep failed_files: AST failure count must persist across rescan cycles
            // so the 3-strike rule can skip AST for hopeless files.
            // Stale entries for now-deleted files are pruned by pruneFailedFiles().
            try db.execute(sql: "DELETE FROM symbols_fts")
        }
    }

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

    // MARK: - Batch writes

    /// Write multiple file results in a single transaction.
    /// Batches: DELETE old symbols → INSERT symbols → INSERT/UPDATE file record → handle failed_files.
    func batchWriteFiles(_ fileResults: [(file: FileRecord, symbols: [SymbolRecord], astFailed: Bool)]) throws {
        try dbQueue.write { db in
            for (fileRec, symbols, astFailed) in fileResults {
                try db.execute(sql: "DELETE FROM symbols WHERE file_path = ?", arguments: [fileRec.path])
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

    /// 自定义 init:startLine/endLine 带默认值 nil,既有调用点(filePath:name:kind:...)
    /// 无需改动即可编译;提取器能算出行号时显式传入。
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
