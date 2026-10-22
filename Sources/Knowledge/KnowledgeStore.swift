import Foundation
import GRDB

/// 一张待展示的知识卡片。**不注册 TableRecord** —— 表由 Python 侧拥有，再声明一份映射必然漂移。
struct KnowledgeCard {
    let id: Int64
    let kind: String
    let title: String
    let subtitle: String
    let theme: String
    let topicKind: String
    let body: String
    let evidenceURLs: [String]
    let topicID: Int64?
}

/// 知识面板的数据访问：**绝不建表、绝不迁移**，每个方法容忍缺表（Swift 可能先于 Python 打开）。
/// 失败一律 `debugLog` 后返回空/false —— 「按钮点了没反应且毫无线索」是最难查的一类问题。
final class KnowledgeStore {
    static let shared = KnowledgeStore()

    private var dbQueue: DatabaseQueue?
    private let lock = NSLock()

    private init() {}

    private var queue: DatabaseQueue? {
        lock.lock()
        defer { lock.unlock() }
        if let dbQueue { return dbQueue }
        var config = Configuration()
        // WAL 与 busy timeout 两侧都必须设：Python 补货子进程与这里同时打开同一个文件，
        // 只设一侧会回落到 delete 模式并互相阻塞。
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        do {
            let q = try DatabaseQueue(path: AppPaths.knowledgeDatabase.path, configuration: config)
            dbQueue = q
            return q
        } catch {
            debugLog("[Knowledge] 打开数据库失败: \(error)")
            return nil
        }
    }

    // MARK: - 读

    /// 从未展示过的卡。补货判据必须用它：旧卡即使允许复习，也不能掩盖需要补新卡的事实。
    func unseenCount(kind: String) -> Int {
        guard let queue else { return 0 }
        do {
            return try queue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM cards WHERE kind = ? AND status = 'pool' AND shown_count = 0",
                    arguments: [kind],
                ) ?? 0
            }
        } catch {
            debugLog("[Knowledge] unseenCount(\(kind)) 失败: \(error)")
            return 0
        }
    }

    /// 取一张池中卡片并累加 `shown_count`：读与写放**同一个写事务**，免得跨进程时自锁。
    /// 默认只取从未展示的卡；`showReviewed` 为 true 时才回退到旧卡。
    func nextCard(
        kind: String,
        excludingTopic: Int64? = nil,
        showReviewed: Bool = false,
        maxShown: Int = 2,
    ) -> KnowledgeCard? {
        guard let queue else { return nil }
        do {
            return try queue.write { db -> KnowledgeCard? in
                var sql = """
                SELECT id, kind, title, subtitle, theme, topic_kind, body, evidence_urls, topic_id
                FROM cards WHERE kind = ? AND status = 'pool'
                """
                var args: [DatabaseValueConvertible] = [kind]
                if let excludingTopic {
                    sql += " AND (topic_id IS NULL OR topic_id != ?)"
                    args.append(excludingTopic)
                }
                if showReviewed {
                    sql += " AND shown_count < ?"
                    args.append(max(1, maxShown))
                    sql += " ORDER BY (shown_count > 0) ASC, last_shown_at ASC, id ASC LIMIT 1"
                } else {
                    sql += " AND shown_count = 0 ORDER BY id ASC LIMIT 1"
                }

                guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args)) else {
                    return nil
                }
                try db.execute(
                    sql: "UPDATE cards SET shown_count = shown_count + 1, last_shown_at = ? WHERE id = ?",
                    arguments: [Self.iso8601(), row["id"] as Int64],
                )
                let urlsJSON: String = row["evidence_urls"] ?? "[]"
                let urls = (try? JSONSerialization.jsonObject(with: Data(urlsJSON.utf8)))
                    as? [String] ?? []
                return KnowledgeCard(
                    id: row["id"], kind: row["kind"], title: row["title"],
                    subtitle: row["subtitle"] ?? "", theme: row["theme"] ?? "",
                    topicKind: row["topic_kind"] ?? "", body: row["body"] ?? "",
                    evidenceURLs: urls, topicID: row["topic_id"],
                )
            }
        } catch {
            debugLog("[Knowledge] nextCard(\(kind)) 失败: \(error)")
            return nil
        }
    }

    // MARK: - 写

    @discardableResult
    func markStatus(cardID: Int64, status: String) -> Bool {
        guard let queue else { return false }
        do {
            try queue.write { db in
                try db.execute(sql: "UPDATE cards SET status = ? WHERE id = ?",
                               arguments: [status, cardID])
            }
            return true
        } catch {
            debugLog("[Knowledge] markStatus(\(cardID) -> \(status)) 失败: \(error)")
            return false
        }
    }

    private static func iso8601() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}
