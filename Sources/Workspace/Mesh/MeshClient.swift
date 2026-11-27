import Foundation

struct MeshCard: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var kind: String
    var ownerGateway: String?
    var transport: String
    var endpoint: String
    var capabilities: [String]
    var status: String
    var startCommand: String?
    var startable: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, kind, transport, endpoint, capabilities, status, startable
        case ownerGateway = "owner_gateway"
        case startCommand = "start_command"
    }

    init(
        id: String,
        name: String,
        kind: String = "workspace",
        ownerGateway: String? = nil,
        transport: String = "directory",
        endpoint: String,
        capabilities: [String] = ["agent"],
        status: String = "ready",
        startCommand: String? = nil,
        startable: Bool = true,
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ownerGateway = ownerGateway
        self.transport = transport
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.status = status
        self.startCommand = startCommand
        self.startable = startable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "workspace"
        ownerGateway = try c.decodeIfPresent(String.self, forKey: .ownerGateway)
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? "directory"
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? id
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ready"
        startCommand = try c.decodeIfPresent(String.self, forKey: .startCommand)
        startable = try c.decodeIfPresent(Bool.self, forKey: .startable) ?? false
    }
}

struct MeshError: LocalizedError, Sendable {
    let code: String
    let message: String

    var errorDescription: String? { "\(code): \(message)" }
}

protocol MeshClientProtocol: Sendable {
    func register(_ card: MeshCard) async throws -> MeshCard
    func touch(serviceID: String, status: String?) async throws
    func deregister(serviceID: String) async throws
    func list() async throws -> [MeshCard]
}

struct MeshClient: MeshClientProtocol, Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            self.session = URLSession(configuration: configuration)
        }
    }

    func register(_ card: MeshCard) async throws -> MeshCard {
        let body: [String: Any] = [
            "id": card.id,
            "name": card.name,
            "kind": card.kind,
            "transport": card.transport,
            "endpoint": card.endpoint,
            "capabilities": card.capabilities,
            "start_command": card.startCommand as Any,
            "startable": card.startable,
        ].compactMapValues { $0 }
        let json = try await post("/mesh/register", body: body)
        guard let stored = json["card"] as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: stored)
        else { throw MeshError(code: "invalid_response", message: "missing card") }
        return try JSONDecoder().decode(MeshCard.self, from: data)
    }

    func touch(serviceID: String, status: String? = nil) async throws {
        var body: [String: Any] = ["service_id": serviceID]
        if let status { body["status"] = status }
        _ = try await post("/mesh/heartbeat", body: body)
    }

    func deregister(serviceID: String) async throws {
        _ = try await post("/mesh/deregister", body: ["service_id": serviceID])
    }

    func list() async throws -> [MeshCard] {
        let json = try await get("/mesh/services")
        let items = json["services"] as? [[String: Any]] ?? []
        let data = try JSONSerialization.data(withJSONObject: items)
        return try JSONDecoder().decode([MeshCard].self, from: data)
    }

    func send(
        sender: String, recipient: String, kind: String, text: String,
        replyTo: String? = nil,
    ) async throws -> String {
        var message: [String: Any] = [
            "sender": sender,
            "recipient": recipient,
            "kind": kind,
            "payload": ["text": text],
        ]
        if let replyTo, !replyTo.isEmpty {
            message["reply_to"] = replyTo
        }
        let json = try await post("/mesh/send", body: ["message": message])
        return json["message_id"] as? String ?? ""
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func get(_ path: String) async throws -> [String: Any] {
        try await send(URLRequest(url: baseURL.appendingPathComponent(path)))
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse else {
            throw MeshError(code: "no_response", message: "missing HTTP response")
        }
        guard http.statusCode < 400, json["ok"] as? Bool != false else {
            let code = json["error_code"] as? String ?? "http_\(http.statusCode)"
            throw MeshError(code: code, message: json["detail"] as? String ?? "")
        }
        return json
    }
}
