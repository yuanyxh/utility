import Foundation

/// Registers workspaces, refreshes heartbeats and prunes removed ones.
@MainActor
final class WorkspaceMeshCoordinator {
    typealias ClientFactory = @MainActor (Int) -> MeshClientProtocol

    private let clientFactory: ClientFactory
    private var client: MeshClientProtocol?
    private var heartbeat: Task<Void, Never>?
    private var registered: Set<String> = []
    private var statuses: [String: String] = [:]
    private var fingerprints: [String: String] = [:]
    private(set) var endpoints: [String: URL] = [:]
    var onRegistered: ((String, URL) -> Void)?

    init(
        clientFactory: @escaping ClientFactory = { port in
            MeshClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        },
    ) {
        self.clientFactory = clientFactory
    }

    var isRunning: Bool { client != nil }

    func sync(
        entries: [(workspace: Workspace, status: String, startCommand: String?)],
        port: Int,
        enabled: Bool,
    ) {
        guard enabled, port > 0 else {
            stop()
            return
        }
        if client == nil {
            client = clientFactory(port)
            startHeartbeat()
        }
        guard let client else { return }
        let desired = Set(entries.map { $0.workspace.id })
        for entry in entries {
            let workspace = entry.workspace
            let fingerprint = Self.fingerprint(
                workspace, status: entry.status, startCommand: entry.startCommand)
            statuses[workspace.id] = entry.status
            if registered.contains(workspace.id), fingerprints[workspace.id] == fingerprint {
                continue
            }
            fingerprints[workspace.id] = fingerprint
            register(
                workspace, status: entry.status, startCommand: entry.startCommand, client: client)
        }
        for serviceID in registered.subtracting(desired) {
            registered.remove(serviceID)
            statuses[serviceID] = nil
            fingerprints[serviceID] = nil
            endpoints[serviceID] = nil
            Task { try? await client.deregister(serviceID: serviceID) }
        }
    }

    private static func fingerprint(
        _ workspace: Workspace, status: String, startCommand: String?,
    ) -> String {
        let config = workspace.protocolConfig
        return [
            workspace.name,
            status,
            config?.serviceName ?? "",
            startCommand ?? "",
            (config?.capabilities ?? []).joined(separator: ","),
        ].joined(separator: "|")
    }

    /// Lets the host report its own state; `pending` from a delivery clears here.
    func report(serviceID: String, status: String) {
        statuses[serviceID] = status
        fingerprints[serviceID] = nil
        guard let client else { return }
        Task { try? await client.touch(serviceID: serviceID, status: status) }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        guard let active = client else { return }
        let ids = registered
        registered = []
        statuses = [:]
        fingerprints = [:]
        endpoints = [:]
        client = nil
        Task { for id in ids { try? await active.deregister(serviceID: id) } }
    }

    private func register(
        _ workspace: Workspace,
        status: String,
        startCommand: String?,
        client: MeshClientProtocol,
    ) {
        let config = workspace.protocolConfig
        let card = MeshCard(
            id: workspace.id,
            name: config?.serviceName ?? workspace.name,
            kind: "workspace",
            endpoint: workspace.id,
            capabilities: config?.capabilities ?? ["agent"],
            status: status,
            startCommand: startCommand,
            startable: startCommand?.isEmpty == false,
        )
        registered.insert(workspace.id)
        Task { [weak self] in
            do {
                let stored = try await client.register(card)
                await MainActor.run {
                    let url = URL(fileURLWithPath: stored.endpoint)
                    self?.endpoints[workspace.id] = url
                    self?.onRegistered?(workspace.id, url)
                }
            } catch {
                debugLog("[Mesh] register \(card.id) failed: \(error)")
                await MainActor.run {
                    self?.registered.remove(workspace.id)
                    self?.fingerprints[workspace.id] = nil
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let client = self.client else { return }
                let ids = self.registered
                for id in ids {
                    let status = self.statuses[id]
                    try? await client.touch(serviceID: id, status: status)
                }
            }
        }
    }
}
