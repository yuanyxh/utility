import Foundation

/// Lightweight publish-subscribe manager
/// - Enum key (Hashable) → multiple (ID, Handler) pairs
/// - Thread-safe (NSLock)
/// - Supports clearing all by key and canceling a single one by ID
public final class EventBus {
    public static let shared = EventBus()

    private var handlers: [AnyHashable: [(id: AnyHashable, handler: (Any?) -> Void)]] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Subscribe

    /// Subscribe to events for the given key
    /// - Parameters:
    ///   - key: Event key (an enum, must be Hashable)
    ///   - id: Subscriber identifier used for later unsubscription (default UUID)
    ///   - handler: Event-handling closure; payload is optional data passed by the publisher
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

    /// Cancel a single subscriber under the given key
    public func unsubscribe(_ key: some Hashable, id: AnyHashable) {
        lock.lock()
        defer { lock.unlock() }
        handlers[AnyHashable(key)]?.removeAll { $0.id == id }
    }

    /// Clear all subscribers for the given key
    public func unsubscribeAll(for key: some Hashable) {
        lock.lock()
        defer { lock.unlock() }
        handlers[AnyHashable(key)] = nil
    }

    // MARK: - Publish

    /// Publish an event to all subscribers
    /// - Parameters:
    ///   - key: Event key
    ///   - payload: Optional payload data
    public func publish(_ key: some Hashable, payload: Any? = nil) {
        lock.lock()
        let subs = handlers[AnyHashable(key)] ?? []
        lock.unlock()
        for sub in subs {
            sub.handler(payload)
        }
    }
}
