import Foundation

/// Runtime debug log — written to ~/.cache/utility/debug.log
/// Used to record operation trace info during APP runtime
/// Rotate by size: when it exceeds DebugLogRotate.maxSize, debug.log → debug.log.1,
/// older backups shift down in turn, keeping at most DebugLogRotate.backupCount copies
public func debugLog(_ msg: String) {
    DebugLogRotate.lock.lock()
    defer { DebugLogRotate.lock.unlock() }

    rotateIfNeeded()
    let logPath = AppPaths.debugLog
    let line = "[\(Date().timeIntervalSince1970)] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}

// MARK: - Size Rotation

private enum DebugLogRotate {
    /// File-size threshold (bytes) that triggers rotation, read from config
    static var maxSize: UInt64 {
        let configured = ConfigManager.shared.config.general.logMaxSize
        return configured > 0 ? UInt64(configured) : 10 * 1024 * 1024
    }

    /// Number of backups kept (debug.log.1 ~ debug.log.N); the oldest backup number N is deleted
    static var backupCount: Int {
        let configured = ConfigManager.shared.config.general.logBackupCount
        return configured > 0 ? configured : 3
    }

    /// Serialize "rotate + write" to avoid multi-threaded race conditions
    static let lock = NSLock()
}

/// Rotate when debug.log exceeds the threshold: delete the oldest backup, shift the remaining backups down, current log becomes .1
private func rotateIfNeeded() {
    let logPath = AppPaths.debugLog
    let fm = FileManager.default

    let size = (try? fm.attributesOfItem(atPath: logPath)[.size] as? UInt64) ?? 0
    guard size >= DebugLogRotate.maxSize else { return }

    // Delete the oldest backup
    try? fm.removeItem(atPath: backupPath(DebugLogRotate.backupCount))

    // Shift down in turn: debug.log.(N-1) → debug.log.N
    for i in stride(from: DebugLogRotate.backupCount - 1, through: 1, by: -1) {
        let from = backupPath(i)
        if fm.fileExists(atPath: from) {
            try? fm.moveItem(atPath: from, toPath: backupPath(i + 1))
        }
    }

    // Current log → debug.log.1
    if fm.fileExists(atPath: logPath) {
        try? fm.moveItem(atPath: logPath, toPath: backupPath(1))
    }
}

private func backupPath(_ i: Int) -> String {
    "\(AppPaths.debugLog).\(i)"
}
