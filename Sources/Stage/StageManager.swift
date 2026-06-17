import Foundation
import GRDB

/// 暂存管理器（GRDB）
public final class StageManager {
    public static let shared = StageManager()
    private var db: DatabaseQueue {
        if let q = AppDatabase.shared.dbQueue { return q }
        try! AppDatabase.shared.setup()
        return AppDatabase.shared.dbQueue
    }

    private init() {}

    // MARK: - CRUD

    public func add(type: String, content: Data) throws {
        let item = StageItem(type: type, content: content)
        try db.write { db in try item.insert(db) }
    }

    public func add(text: String) throws {
        try add(type: "text", content: text.data(using: .utf8) ?? Data())
    }

    public func add(fileURL url: URL) throws {
        let bookmark = try url.bookmarkData(options: [],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        try add(type: "fileURL", content: bookmark)
    }

    public func add(imageData: Data) throws {
        try add(type: "image", content: imageData)
    }

    public func add(url: URL) throws {
        try add(type: "url", content: url.absoluteString.data(using: .utf8) ?? Data())
    }

    public func remove(_ id: String) throws {
        try db.write { db in
            try StageItem.deleteOne(db, key: id)
        }
    }

    public func clearAll() throws {
        try db.write { db in
            try db.execute(literal: "DELETE FROM stage_item")
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
