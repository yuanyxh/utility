import Foundation
import GRDB

/// RSS 管理器（GRDB）
/// Headless 设计，供 CLI 和 Hermes Agent 调用
public final class RSSManager {
    public static let shared = RSSManager()
    private var db: DatabaseQueue {
        if let q = AppDatabase.shared.dbQueue { return q }
        try! AppDatabase.shared.setup()
        return AppDatabase.shared.dbQueue
    }

    private init() {}

    /// 抓取所有订阅源，合并新条目到数据库
    @discardableResult
    public func fetchAll() async throws -> [RSSItem] {
        let feeds = ConfigManager.shared.config.rss.feeds
        guard !feeds.isEmpty else {
            Log.debug("[RSS] No feeds configured")
            return []
        }

        var allNew: [RSSItem] = []

        for feed in feeds {
            guard let url = URL(string: feed.url) else {
                Log.debug("[RSS] Invalid URL: \(feed.url)")
                continue
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let parser = RSSParser()
                let newItems = parser.parse(data: data, feedName: feed.name)
                let inserted = try addIfNew(newItems)
                allNew.append(contentsOf: inserted)
                Log.debug("[RSS] \(feed.name): \(inserted.count) new / \(newItems.count) total")
            } catch {
                Log.debug("[RSS] Failed to fetch \(feed.name): \(error)")
            }
        }

        return allNew
    }

    /// 去重插入新条目
    private func addIfNew(_ items: [RSSItem]) throws -> [RSSItem] {
        var inserted: [RSSItem] = []
        try db.write { db in
            for item in items {
                let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_item WHERE id = ?",
                                              arguments: [item.id]) ?? 0
                if exists == 0 {
                    try item.insert(db)
                    inserted.append(item)
                }
            }
        }
        return inserted
    }

    // MARK: - Query

    public func unread() throws -> [RSSItem] {
        try db.read { db in
            try RSSItem
                .filter(Column("is_read") == false)
                .order(Column("pub_date").desc)
                .fetchAll(db)
        }
    }

    public func all() throws -> [RSSItem] {
        try db.read { db in
            try RSSItem
                .order(Column("pub_date").desc)
                .fetchAll(db)
        }
    }

    public func markAsRead(_ id: String) throws {
        try db.write { db in
            try db.execute(literal: "UPDATE rss_item SET is_read = 1 WHERE id = \(id)")
        }
    }

    public func markAllAsRead() throws {
        try db.write { db in
            try db.execute(literal: "UPDATE rss_item SET is_read = 1")
        }
    }

    public func count() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rss_item") ?? 0 }
    }

    public func unreadCount() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rss_item WHERE is_read = 0") ?? 0 }
    }
}
