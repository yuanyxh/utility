import Foundation
import GRDB

/// 剪切板存储（GRDB）
public final class ClipboardStorage {
    private let db: DatabaseQueue

    public init() {
        self.db = AppDatabase.shared.dbQueue
    }

    // MARK: - CRUD

    public func add(_ item: ClipboardItem) throws {
        try db.write { db in
            try item.insert(db)

            // 1. 按保留天数清理
            let maxDays = ConfigManager.shared.config.clipboard.maxDays
            let cutoff = Date().addingTimeInterval(-Double(maxDays * 86400))
            try db.execute(literal: """
                DELETE FROM clipboard_item WHERE timestamp < \(cutoff)
            """)

            // 2. 限制最大条目数
            let maxItems = ConfigManager.shared.config.clipboard.maxItems
            try db.execute(literal: """
                DELETE FROM clipboard_item WHERE id NOT IN (
                    SELECT id FROM clipboard_item ORDER BY timestamp DESC LIMIT \(maxItems)
                )
            """)
        }
    }

    public func all() throws -> [ClipboardItem] {
        try db.read { db in
            try ClipboardItem
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    public func search(_ query: String) throws -> [ClipboardItem] {
        let pattern = "%\(query)%"
        return try db.read { db in
            try ClipboardItem
                .filter(Column("search_text").like(pattern))
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    public func moveToTop(_ id: String) throws {
        try db.write { db in
            try db.execute(literal: """
                UPDATE clipboard_item SET timestamp = \(Date()) WHERE id = \(id)
            """)
        }
    }

    public func count() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clipboard_item") ?? 0 }
    }
}
