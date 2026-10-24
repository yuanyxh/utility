import Foundation
import GRDB

/// 一张待展示的知识卡片。**不注册 TableRecord** —— 表由 Python 侧拥有，再声明一份映射必然漂移。
struct KnowledgeEvidence {
    let url: String
    let title: String
}

struct KnowledgeCard {
    let id: Int64
    let kind: String
    let title: String
    let subtitle: String
    let theme: String
    let topicKind: String
    let body: String
    let evidence: [KnowledgeEvidence]
    let topicID: Int64?
}

/// Lightweight row for the list tab: never loads `body` / `evidence` (a few KB per card).
struct KnowledgeCardSummary {
    let id: Int64
    let title: String
    let theme: String
    let status: String
    let createdAt: String
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
                return Self.card(from: row)
            }
        } catch {
            debugLog("[Knowledge] nextCard(\(kind)) 失败: \(error)")
            return nil
        }
    }

    /// Read-only fetch for the list preview: **does not touch `shown_count`**, so the
    /// rotation position stays exactly where it was.
    func card(id: Int64, kind: String) -> KnowledgeCard? {
        guard let queue else { return nil }
        do {
            return try queue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, kind, title, subtitle, theme, topic_kind, body, evidence_urls, topic_id
                    FROM cards WHERE id = ? AND kind = ? AND status IN ('pool', 'liked')
                    """,
                    arguments: [id, kind],
                ) else { return nil }
                return Self.card(from: row)
            }
        } catch {
            debugLog("[Knowledge] card(\(id)) 失败: \(error)")
            return nil
        }
    }

    /// Newest first; `removed` / `disliked` are not part of the normal library.
    func listCards(kind: String, limit: Int = 1000) -> [KnowledgeCardSummary] {
        guard let queue else { return [] }
        do {
            return try queue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, title, theme, status, created_at FROM cards
                    WHERE kind = ? AND status IN ('pool', 'liked')
                    ORDER BY id DESC LIMIT ?
                    """,
                    arguments: [kind, max(1, limit)],
                ).map {
                    KnowledgeCardSummary(
                        id: $0["id"], title: $0["title"], theme: $0["theme"] ?? "",
                        status: $0["status"], createdAt: $0["created_at"] ?? "",
                    )
                }
            }
        } catch {
            debugLog("[Knowledge] listCards(\(kind)) 失败: \(error)")
            return []
        }
    }

    private static func card(from row: Row) -> KnowledgeCard {
        let raw: String = row["evidence_urls"] ?? "[]"
        return KnowledgeCard(
            id: row["id"], kind: row["kind"], title: row["title"],
            subtitle: row["subtitle"] ?? "", theme: row["theme"] ?? "",
            topicKind: row["topic_kind"] ?? "", body: row["body"] ?? "",
            evidence: evidenceList(raw), topicID: row["topic_id"],
        )
    }

    /// Accept both shapes: legacy `["url"]` and the current `[{"url","title"}]`.
    private static func evidenceList(_ raw: String) -> [KnowledgeEvidence] {
        guard let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return items.compactMap { item in
            if let url = item as? String {
                return normalizedEvidenceURL(url).map {
                    KnowledgeEvidence(url: $0, title: "")
                }
            }
            if let dict = item as? [String: Any],
               let url = dict["url"] as? String,
               let normalized = normalizedEvidenceURL(url)
            {
                return KnowledgeEvidence(
                    url: normalized, title: dict["title"] as? String ?? "",
                )
            }
            return nil
        }
    }

    /// 旧卡可能存着搜索引擎结果页；展示前统一过滤并规范化，避免出现不可点击的长链接。
    private static func normalizedEvidenceURL(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return nil }
        let path = url.path.lowercased()
        let enginePages: [(String, String)] = [
            ("www.sogou.com", "/sogou"), ("www.sogou.com", "/web"),
            ("www.baidu.com", "/s"), ("www.so.com", "/s"), ("ai.so.com", "/search"),
            ("www.bing.com", "/search"), ("cn.bing.com", "/search"),
            ("html.duckduckgo.com", "/html/"), ("search.brave.com", "/search"),
            ("old-search.marginalia.nu", "/search"),
        ]
        if enginePages.contains(where: { host == $0.0 && path.hasPrefix($0.1) }) {
            return nil
        }
        return url.absoluteString
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
