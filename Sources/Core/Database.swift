import Foundation
import GRDB

public final class AppDatabase {
    public static let shared = AppDatabase()
    public var dbQueue: DatabaseQueue!

    private init() {}

    public func setup() throws {
        try FileManager.default.createDirectory(at: AppPaths.configDir, withIntermediateDirectories: true)
        let dbPath = AppPaths.database.path
        dbQueue = try DatabaseQueue(path: dbPath)
        try migrator.migrate(dbQueue)
        debugLog("[Database] Opened at \(dbPath)")
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // 剪切板条目
            try db.create(table: "clipboard_item", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull()
                t.column("type", .text).notNull()   // text / file / image
                t.column("content", .blob).notNull()
                t.column("application", .text)
                t.column("search_text", .text)      // 文本纯内容索引
            }
            try db.execute(literal: """
                CREATE INDEX IF NOT EXISTS idx_clipboard_timestamp
                ON clipboard_item(timestamp DESC)
            """)

            // 暂存条目
            try db.create(table: "stage_item", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull()
                t.column("type", .text).notNull()   // text / fileURL
                t.column("content", .blob).notNull()
            }
            try db.execute(literal: """
                CREATE INDEX IF NOT EXISTS idx_stage_timestamp
                ON stage_item(timestamp DESC)
            """)

            // RSS 条目
            try db.create(table: "rss_item", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("link", .text).notNull()
                t.column("item_description", .text).notNull()
                t.column("pub_date", .datetime).notNull()
                t.column("feed_name", .text).notNull()
                t.column("is_read", .boolean).notNull().defaults(to: false)
            }
            try db.execute(literal: """
                CREATE INDEX IF NOT EXISTS idx_rss_pubdate
                ON rss_item(pub_date DESC)
            """)
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "task_state", ifNotExists: true) { t in
                t.column("task_name", .text).primaryKey()
                t.column("last_fire", .double).notNull()
            }
        }

        return migrator
    }
}
