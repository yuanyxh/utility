import Foundation

/// 轻量发布订阅管理器
/// - 枚举 Key（Hashable）→ 多个 (ID, Handler)
/// - 线程安全（NSLock）
/// - 支持按 key 清除全部、按 ID 取消单个
public final class EventBus {
    public static let shared = EventBus()

    private var handlers: [AnyHashable: [(id: AnyHashable, handler: (Any?) -> Void)]] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Subscribe

    /// 订阅指定 key 的事件
    /// - Parameters:
    ///   - key: 事件键（枚举，需 Hashable）
    ///   - id: subscriber 标识，用于后续取消订阅（默认 UUID）
    ///   - handler: 事件处理闭包，payload 为发布方传入的可选数据
    @discardableResult
    public func subscribe(
        _ key: some Hashable,
        id: AnyHashable = UUID(),
        handler: @escaping (Any?) -> Void,
    ) -> AnyHashable {
        lock.lock()
        defer { lock.unlock() }
        let anyKey = AnyHashable(key)
        if handlers[anyKey] == nil {
            handlers[anyKey] = []
        }
        handlers[anyKey]?.append((id: id, handler: handler))
        return id
    }

    // MARK: - Unsubscribe

    /// 取消指定 key 下的单个 subscriber
    public func unsubscribe(_ key: some Hashable, id: AnyHashable) {
        lock.lock()
        defer { lock.unlock() }
        handlers[AnyHashable(key)]?.removeAll { $0.id == id }
    }

    /// 清除指定 key 的全部 subscriber
    public func unsubscribeAll(for key: some Hashable) {
        lock.lock()
        defer { lock.unlock() }
        handlers[AnyHashable(key)] = nil
    }

    // MARK: - Publish

    /// 发布事件到所有订阅者
    /// - Parameters:
    ///   - key: 事件键
    ///   - payload: 可选负载数据
    public func publish(_ key: some Hashable, payload: Any? = nil) {
        lock.lock()
        let subs = handlers[AnyHashable(key)] ?? []
        lock.unlock()
        for sub in subs {
            sub.handler(payload)
        }
    }
}
