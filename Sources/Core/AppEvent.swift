import Foundation

/// 应用级事件枚举 — 仅作事件标识
/// 负载数据通过 EventBus.publish(key:payload:) 的 payload 参数传递
enum AppEvent: String, Hashable, CaseIterable {
    // MARK: - Config

    case configDidLoad
    case configLoadFailed
    case configReloadFailed

    // MARK: - Database

    case databaseInitFailed

    // MARK: - Hotkey

    case hotkeyParseFailed
    case hotkeyRegistrationFailed

    // MARK: - Task

    case taskDidFail
    case launchAtLoginFailed

    // MARK: - RSS

    case rssFetchFailed

    // MARK: - Network

    case networkSpeedUpdated
}
