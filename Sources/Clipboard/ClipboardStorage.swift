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
            // 查找重复项：text 按 plainText，其他按 content 逐字节对比
            let dupeId: String? = {
                if item.type == "text", let text = item.plainText {
                    return try? String.fetchOne(
                        db,
                        sql: """
                            SELECT id FROM clipboard_item
                            WHERE type = 'text' AND search_text = ?
                            LIMIT 1
                        """, arguments: [text]
                    )
                }
                // file / file_batch / html — 按 content 匹配
                let existing =
                    (try? ClipboardItem
                        .filter(Column("type") == item.type)
                        .fetchAll(db)) ?? []
                return existing.first(where: { $0.content == item.content })?.id
            }()

            if let existingId = dupeId {
                // 重复 → 更新时间戳移到顶部
                try db.execute(
                    literal: """
                        UPDATE clipboard_item SET timestamp = \(Date()) WHERE id = \(existingId)
                    """
                )
            } else {
                try item.insert(db)
                let maxDays = ConfigManager.shared.config.clipboard.maxDays
                let cutoff = Date().addingTimeInterval(-Double(maxDays * 86400))
                try db.execute(
                    literal: """
                        DELETE FROM clipboard_item WHERE timestamp < \(cutoff)
                    """
                )
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

    public func moveToTop(_ id: String) throws {
        try db.write { db in
            try db.execute(
                literal: """
                    UPDATE clipboard_item SET timestamp = \(Date()) WHERE id = \(id)
                """
            )
        }
    }

    public func count() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clipboard_item") ?? 0 }
    }
}
