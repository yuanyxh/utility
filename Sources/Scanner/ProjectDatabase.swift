import Foundation
import GRDB

/// Manages `.utility/deps.sqlite` for a specific project directory.
final class ProjectDatabase {
    /// 依赖图数据库文件名（Scanner/FileWatcher/AgentRunner 共用单一权威）
    static let depsFilename = "deps.sqlite"

    let dbQueue: DatabaseQueue

    init(projectPath: String) throws {
        let utilityDir = (projectPath as NSString).appendingPathComponent(".utility")
        try FileManager.default.createDirectory(atPath: utilityDir, withIntermediateDirectories: true)
        let dbPath = (utilityDir as NSString).appendingPathComponent(Self.depsFilename)
        // 多连接并发写 deps.sqlite（Scanner 全量 + FileWatcher 增量 + MCP 读），
        // GRDB 默认 busyMode=.immediateError 锁冲突立即失败；改 .timeout(5) 等锁而非失败
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

        return migrator
    }

    // MARK: - Helpers

    // 清空逻辑不再作为独立方法暴露：它必须与写入处于同一事务，见
    // `replaceScanResults`。单独留一个可从外部调用的 `clearAll()`，会诱导
    // 后来者在扫描开头清库，从而把这个空窗重新引入。

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

    /// 原子替换全部扫描结果：单事务内完成「清空 → 写入 → 重建 FTS」。
    ///
    /// 旧流程是 `clearAll()` 先独立提交，等 Phase 1 遍历与 Phase 2 提取（大项目
    /// 数十秒）跑完才写回。这个窗口内库对 MCP 读者是空的——检索工具一律返回空
    /// 结果，模型据此判定「代码不存在」，可能重复实现已有功能；扫描中途被中断
    /// （Ctrl-C、OOM、抛错）则空库一直留到下次扫描才恢复。改为单事务后，读者
    /// 要么看到完整的旧结果、要么看到完整的新结果，不存在中间态。
    ///
    /// 目录写入也一并纳入：原先 `insertDirectory` 在空窗期内单独提交，库会停在
    /// 「目录有了、符号还没有」的不一致状态。
    ///
    /// `failed_files` 有意不清空：AST 连败计数的 3-strike 记忆必须跨扫描保留，
    /// 已消失文件的条目由 `pruneFailedFiles` 负责清理。
    func replaceScanResults(
        directories: [DirectoryRecord],
        files: [(file: FileRecord, symbols: [SymbolRecord], astFailed: Bool)],
        packages: [PackageRecord],
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM directories")
            try db.execute(sql: "DELETE FROM files")
            try db.execute(sql: "DELETE FROM symbols")
            try db.execute(sql: "DELETE FROM packages")

            for dir in directories {
                try dir.insert(db, onConflict: .replace)
            }

            // 符号表已整体清空，无需再按 file_path 逐条删。
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

            // FTS 必须在同一事务内 rebuild：symbols_fts 是 external content 表，
            // content 行被删后 `DELETE FROM symbols_fts` 摘不出词（是空操作），
            // 只有 rebuild 能让倒排表与 symbols 对齐。放事务内保证提交瞬间两者一致。
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
