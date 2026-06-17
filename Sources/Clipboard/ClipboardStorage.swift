import Foundation
import GRDB

/// 剪切板存储（GRDB）
public final class ClipboardStorage {
    private var db: DatabaseQueue {
        if let q = AppDatabase.shared.dbQueue { return q }
        try! AppDatabase.shared.setup()
        return AppDatabase.shared.dbQueue
    }

    public init() {}

    // MARK: - CRUD

    public func add(_ item: ClipboardItem) throws {
        try db.write { db in
            // 查找重复项：文本比较 search_text，图片/batch 比较 content 数据
            let dupeId: String? = {
                if item.type == "text", let text = item.searchText {
                    return try? String.fetchOne(db, sql: """
                        SELECT id FROM clipboard_item
                        WHERE type = 'text' AND search_text = ?
                        LIMIT 1
                    """, arguments: [text])
                } else if item.type == "image" || item.type == "image_batch" {
                    return try? String.fetchOne(db, sql: """
                        SELECT id FROM clipboard_item
                        WHERE type = ? AND content = ?
                        LIMIT 1
                    """, arguments: [item.type, item.content])
                }
                return nil
            }()

            if let existingId = dupeId {
                // 重复 → 更新时间戳移到顶部
                try db.execute(literal: """
                    UPDATE clipboard_item SET timestamp = \(Date()) WHERE id = \(existingId)
                """)
            } else {
                // 新条目 → 正常插入
                try item.insert(db)

                // 按保留天数清理
                let maxDays = ConfigManager.shared.config.clipboard.maxDays
                let cutoff = Date().addingTimeInterval(-Double(maxDays * 86400))
                try db.execute(literal: """
                    DELETE FROM clipboard_item WHERE timestamp < \(cutoff)
                """)

                // 限制最大条目数
                let maxItems = ConfigManager.shared.config.clipboard.maxItems
                try db.execute(literal: """
                    DELETE FROM clipboard_item WHERE id NOT IN (
                        SELECT id FROM clipboard_item ORDER BY timestamp DESC LIMIT \(maxItems)
                    )
                """)
            }
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
