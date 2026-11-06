import Foundation

/// Single source of truth for workspace UI state. Observers only render.
@MainActor
final class WorkspaceStateStore {
    private(set) var snapshot: WorkspaceSnapshot
    private var observers: [UUID: (WorkspaceSnapshot) -> Void] = [:]

    init(snapshot: WorkspaceSnapshot = WorkspaceSnapshot()) {
        self.snapshot = snapshot
    }

    func update(_ mutate: (inout WorkspaceSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else {
            debugLog("[State] changed=false notified=0")
            return
        }
        snapshot = next
        let handlers = Array(observers.values)
        debugLog("[State] changed=true notified=\(handlers.count)")
        for handler in handlers { handler(next) }
    }

    func observe(_ handler: @escaping (WorkspaceSnapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func cancel(_ token: UUID) {
        observers[token] = nil
    }
}
