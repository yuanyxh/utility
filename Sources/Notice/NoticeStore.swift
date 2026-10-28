import Foundation
import GRDB

/// A reminder row: written by `utility notice`, delivered and removed by the app.
public struct NoticeRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notice"

    public var id: String
    public var title: String
    public var body: String
    public var dueAt: Date
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, body
        case dueAt = "due_at"
        case createdAt = "created_at"
    }

    public init(id: String, title: String, body: String, dueAt: Date, createdAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.dueAt = dueAt
        self.createdAt = createdAt
    }
}

/// `notices.sqlite` is opened by both the CLI and the app, so it needs WAL + busy timeout.
public final class NoticeStore {
    public static let shared = NoticeStore()

    private let lock = NSLock()
    private var dbQueue: DatabaseQueue?

    private init() {}

    public func open() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        if let dbQueue { return dbQueue }
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        try FileManager.default.createDirectory(
            at: AppPaths.configDir, withIntermediateDirectories: true,
        )
        let queue = try DatabaseQueue(path: AppPaths.noticesDatabase.path, configuration: config)
        try createTable(queue)
        dbQueue = queue
        return queue
    }

    private func createTable(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.create(table: NoticeRecord.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("due_at", .datetime).notNull().indexed()
                t.column("created_at", .datetime).notNull()
            }
        }
    }

    @discardableResult
    public func add(title: String, body: String, dueAt: Date) throws -> NoticeRecord {
        let record = NoticeRecord(
            id: UUID().uuidString,
            title: title,
            body: body,
            dueAt: dueAt,
            createdAt: Date(),
        )
        try open().write { db in try record.insert(db) }
        return record
    }

    public func due(now: Date = Date()) throws -> [NoticeRecord] {
        try open().read { db in
            try NoticeRecord
                .filter(Column("due_at") <= now)
                .order(Column("due_at"))
                .fetchAll(db)
        }
    }

    public func all() throws -> [NoticeRecord] {
        try open().read { db in
            try NoticeRecord.order(Column("due_at")).fetchAll(db)
        }
    }

    public func remove(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try open().write { db in
            _ = try NoticeRecord.deleteAll(db, keys: ids)
        }
    }
}
