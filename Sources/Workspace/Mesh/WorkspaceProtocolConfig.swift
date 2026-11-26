import Foundation

/// Per-workspace mesh settings; a nil field keeps the default behaviour.
struct WorkspaceProtocolConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var startCommand: String?
    var serviceName: String?
    var capabilities: [String]

    init(
        enabled: Bool = true,
        startCommand: String? = nil,
        serviceName: String? = nil,
        capabilities: [String] = ["agent"],
    ) {
        self.enabled = enabled
        self.startCommand = startCommand
        self.serviceName = serviceName
        self.capabilities = capabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        startCommand = try c.decodeIfPresent(String.self, forKey: .startCommand)
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? ["agent"]
    }
}

extension WorkspaceProtocolConfig {
    /// Per-workspace command wins; blank values fall through to the fallback.
    static func resolvedStartCommand(own: String?, fallback: String?) -> String? {
        for candidate in [own, fallback] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            {
                return value
            }
        }
        return nil
    }
}

/// Mesh only runs behind an enabled gateway; either side being off disables it.
enum MeshGate {
    static func isEnabled(
        mcpEnabled: Bool,
        gatewayAvailable: Bool,
        gatewayRunning: Bool,
    ) -> Bool {
        mcpEnabled && gatewayAvailable && gatewayRunning
    }

    @MainActor
    static var isEnabled: Bool {
        isEnabled(
            mcpEnabled: ConfigManager.shared.config.mcp?.enabled == true,
            gatewayAvailable: PythonScriptRunner.isGatewayAvailable,
            gatewayRunning: MCPProcessManager.shared.state == .running,
        )
    }
}
