import Foundation

/// 日志工具 — debug 模式打印，release 模式静默
public enum Log {
    /// 仅在 DEBUG 编译条件下输出
    @inlinable
    public static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }
}
