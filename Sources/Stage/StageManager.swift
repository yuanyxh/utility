import Foundation
import GRDB

/// 暂存管理器（GRDB）
/// 自动接收拖拽到菜单栏的文件/文本
public final class StageManager {
    public static let shared = StageManager()
    private var db: DatabaseQueue {
        if let q = AppDatabase.shared.dbQueue { return q }
        // 延迟初始化（可能在 setup() 之前被调用）
        try! AppDatabase.shared.setup()
        return AppDatabase.shared.dbQueue
    }

    private init() {}

    // MARK: - CRUD

    public func add(text: String) throws {
        let item = StageItem(type: "text",
                              content: text.data(using: .utf8) ?? Data())
        try db.write { db in try item.insert(db) }
    }

    public func add(fileURL url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        let item = StageItem(type: "fileURL", content: bookmark)
        try db.write { db in try item.insert(db) }
    }

    public func remove(_ id: String) throws {
        try db.write { db in
            try StageItem.deleteOne(db, key: id)
        }
    }

    public func all() throws -> [StageItem] {
        try db.read { db in
            try StageItem
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stage_item") ?? 0 }
    }
}
