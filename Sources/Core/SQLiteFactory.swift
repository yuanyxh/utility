import Foundation
import GRDB

/// Single place for SQLite open options. GRDB defaults to `busyMode = .immediateError`,
/// which turns a concurrent writer into an instant failure, so every store opts into a wait.
enum SQLiteFactory {
    static func open(
        path: String,
        journal: Configuration.JournalModeConfiguration = .default,
        busyTimeout: TimeInterval = 5,
    ) throws -> DatabaseQueue {
        var config = Configuration()
        config.journalMode = journal
        config.busyMode = .timeout(busyTimeout)
        return try DatabaseQueue(path: path, configuration: config)
    }
}
