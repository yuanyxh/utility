import Foundation

/// 运行时调试日志 — 写入 ~/.cache/utility/debug.log
/// 用于记录 APP 运行时的操作追踪信息
/// 按大小轮转:超过 DebugLogRotate.maxSize 时 debug.log → debug.log.1,
/// 旧备份依次后移,最多保留 DebugLogRotate.backupCount 份
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

// MARK: - 大小轮转

private enum DebugLogRotate {
    /// 触发轮转的文件大小阈值(字节)
    static let maxSize: UInt64 = 10 * 1024 * 1024
    /// 保留的备份份数(debug.log.1 ~ debug.log.N),最旧的 N 号备份会被删除
    static let backupCount = 3
    /// 串行化「轮转 + 写入」,避免多线程并发竞态
    static let lock = NSLock()
}

/// debug.log 超过阈值时执行轮转:删除最旧备份,剩余备份依次后移,当前日志成为 .1
private func rotateIfNeeded() {
    let logPath = AppPaths.debugLog
    let fm = FileManager.default

    let size = (try? fm.attributesOfItem(atPath: logPath)[.size] as? UInt64) ?? 0
    guard size >= DebugLogRotate.maxSize else { return }

    // 删除最旧备份
    try? fm.removeItem(atPath: backupPath(DebugLogRotate.backupCount))

    // 依次后移:debug.log.(N-1) → debug.log.N
    for i in stride(from: DebugLogRotate.backupCount - 1, through: 1, by: -1) {
        let from = backupPath(i)
        if fm.fileExists(atPath: from) {
            try? fm.moveItem(atPath: from, toPath: backupPath(i + 1))
        }
    }

    // 当前日志 → debug.log.1
    if fm.fileExists(atPath: logPath) {
        try? fm.moveItem(atPath: logPath, toPath: backupPath(1))
    }
}

private func backupPath(_ i: Int) -> String {
    "\(AppPaths.debugLog).\(i)"
}
