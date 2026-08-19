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

    private init() {
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.cleanupStaleFeeds()
        }
    }

    // MARK: - Stale cleanup

    /// 删除配置中已不存在的 feed 的历史条目
    private func cleanupStaleFeeds() {
        let configuredNames = Set(ConfigManager.shared.config.rss.feeds.map(\.name))
        let dbFeedNames: Set<String>
        do {
            dbFeedNames = try db.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT feed_name FROM rss_item")
                return Set(rows.compactMap { $0["feed_name"] as String? })
            }
        } catch {
            debugLog("[RSS] cleanupStaleFeeds read failed: \(error)")
            return
        }
        let stale = dbFeedNames.filter { !configuredNames.contains($0) }
        for name in stale {
            do {
                try db.write { db in
                    try db.execute(literal: "DELETE FROM rss_item WHERE feed_name = \(name)")
                }
            } catch {
                debugLog("[RSS] cleanupStaleFeeds delete '\(name)' failed: \(error)")
            }
        }
    }

    /// 抓取所有订阅源，合并新条目到数据库
    @discardableResult
    public func fetchAll() async throws -> [RSSItem] {
        let feeds = ConfigManager.shared.config.rss.feeds
        guard !feeds.isEmpty else {
            return []
        }

        var allNew: [RSSItem] = []

        for feed in feeds {
            guard let url = URL(string: feed.url) else { continue }
            do {
                let resp = try await HTTP.get(url: url)
                let parser = RSSParser()
                let newItems = parser.parse(data: resp.data, feedName: feed.name)
                let inserted = try addIfNew(newItems)
                allNew.append(contentsOf: inserted)
            } catch {
                debugLog("[RSS] Failed to fetch \(feed.name): \(error)")
            }
        }

        return allNew
    }

    /// 去重插入新条目
    private func addIfNew(_ items: [RSSItem]) throws -> [RSSItem] {
        var inserted: [RSSItem] = []
        try db.write { db in
            for item in items {
                let exists =
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM rss_item WHERE id = ?",
                        arguments: [item.id],
                    ) ?? 0
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
        try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rss_item WHERE is_read = 0") ?? 0
        }
    }
}
