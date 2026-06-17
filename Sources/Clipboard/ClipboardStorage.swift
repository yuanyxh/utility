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
            // 查找重复项
            let dupeId: String? = {
                if item.type == "text", let text = item.searchText {
                    return try? String.fetchOne(db, sql: """
                        SELECT id FROM clipboard_item
                        WHERE type = 'text' AND search_text = ?
                        LIMIT 1
                    """, arguments: [text])
                } else if item.type == "image" || item.type == "image_batch" {
                    // 解码当前条目原始图片数据
                    guard let currentRaw = Self.rawImageData(from: item) else { return nil }
                    // 遍历同类型已有条目，解码后逐字节对比
                    let existing = try ClipboardItem
                        .filter(Column("type") == item.type)
                        .fetchAll(db)
                    for ex in existing {
                        guard let exRaw = Self.rawImageData(from: ex) else { continue }
                        if currentRaw == exRaw { return ex.id }
                    }
                    return nil
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

    /// 从 ClipboardItem 中解码出原始图片数据（用于去重对比）
    private static func rawImageData(from item: ClipboardItem) -> Data? {
        if item.type == "image" {
            guard let dict = try? NSKeyedUnarchiver.unarchiveObject(with: item.content) as? [String: Any],
                  let data = dict["data"] as? Data else { return nil }
            return data
        }
        if item.type == "image_batch" {
            guard let dicts = try? NSKeyedUnarchiver.unarchiveObject(with: item.content) as? [[String: Any]] else { return nil }
            var all = Data()
            for d in dicts {
                if let data = d["data"] as? Data { all.append(data) }
            }
            return all
        }
        return nil
    }
}
