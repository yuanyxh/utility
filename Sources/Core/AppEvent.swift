import Foundation

/// 通知 payload——发布者自行构建 title/body
struct NotificationPayload {
  let title: String
  let body: String
}

/// 应用级事件枚举
enum AppEvent: String, Hashable, CaseIterable {
  case configDidLoad
  case notify  // payload: NotificationPayload
  case networkSpeedUpdated
}

/// 面板事件 — pub/sub 字符串 key，payload 携带参数
enum PanelEvent {
  /// 请求显示面板，payload: PanelProtocol 实例
  static let requestShow = "panel.requestShow"
  /// 请求关闭面板，payload: PanelProtocol 实例
  static let requestClose = "panel.requestClose"
  /// 请求粘贴并关闭，payload: PanelProtocol 实例
  /// PanelManager 取 originatingApp → schedulePaste → 关面板
  static let requestPaste = "panel.requestPaste"
}
