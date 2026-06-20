import Foundation
import GRDB

public final class TaskStateDB {
    public static let shared = TaskStateDB()

    private var dbQueue: DatabaseQueue? {
        AppDatabase.shared.dbQueue
    }

    private init() {}

    /// 获取任务的上次触发时间
    public func lastFire(for taskName: String) -> Date? {
        guard let db = dbQueue else { return nil }
        return try? db.read { db in
            if let ts: Double = try Double.fetchOne(db, sql: "SELECT last_fire FROM task_state WHERE task_name = ?", arguments: [taskName]) {
                return Date(timeIntervalSince1970: ts)
            }
            return nil
        }
    }

    /// 更新任务的上次触发时间
    public func setLastFire(_ date: Date, for taskName: String) {
        guard let db = dbQueue else { return }
        try? db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO task_state (task_name, last_fire) VALUES (?, ?)",
                arguments: [taskName, date.timeIntervalSince1970]
            )
        }
    }

    /// 删除指定任务记录
    public func remove(taskName: String) {
        guard let db = dbQueue else { return }
        try? db.write { db in
            try db.execute(sql: "DELETE FROM task_state WHERE task_name = ?", arguments: [taskName])
        }
    }

    /// 获取所有已记录的任务名
    public func allTaskNames() -> [String] {
        guard let db = dbQueue else { return [] }
        return (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT task_name FROM task_state")
        }) ?? []
    }
}
