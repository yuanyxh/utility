import Foundation

/// 运行时调试日志 — 写入 ~/.cache/utility/debug.log
/// 用于记录 APP 运行时的操作追踪信息
public func debugLog(_ msg: String) {
    #if DEBUG
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
    #endif
}
