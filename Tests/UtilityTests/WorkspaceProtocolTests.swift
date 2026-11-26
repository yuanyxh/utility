import XCTest

@testable import utility

final class WorkspaceProtocolTests: XCTestCase {
    func testLegacyDocumentLoadsWithoutProtocol() throws {
        let json = """
            {"version":2,"workspaces":[{"id":"ws-1","name":"a","path":"/tmp","subSessionIDs":[]}]}
            """
        let document = try WorkspaceJSON.decode(Data(json.utf8))
        XCTAssertEqual(document.workspaces.count, 1)
        XCTAssertNil(document.workspaces[0].protocolConfig)
    }

    func testNormalizedKeepsProtocol() {
        let workspace = Workspace(
            id: "ws-1",
            name: "a",
            path: "/tmp",
            protocolConfig: WorkspaceProtocolConfig(startCommand: "claude"),
        )
        let document = WorkspaceDocument(workspaces: [workspace]).normalized()
        XCTAssertEqual(document.workspaces.first?.protocolConfig?.startCommand, "claude")
    }

    func testEncodeOmitsNilProtocol() throws {
        let document = WorkspaceDocument(workspaces: [Workspace(id: "ws-1", name: "a", path: "/tmp")])
        let data = try WorkspaceJSON.encode(document)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"protocol\""))
    }

    func testEncodeWritesProtocol() throws {
        let workspace = Workspace(
            id: "ws-1",
            name: "a",
            path: "/tmp",
            protocolConfig: WorkspaceProtocolConfig(serviceName: "utility"),
        )
        let data = try WorkspaceJSON.encode(WorkspaceDocument(workspaces: [workspace]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"protocol\""))
        XCTAssertTrue(text.contains("utility"))
    }

    func testMeshGateMatrix() {
        XCTAssertTrue(
            MeshGate.isEnabled(
                mcpEnabled: true, gatewayAvailable: true, gatewayRunning: true))
        XCTAssertFalse(
            MeshGate.isEnabled(
                mcpEnabled: false, gatewayAvailable: true, gatewayRunning: true))
        XCTAssertFalse(
            MeshGate.isEnabled(
                mcpEnabled: true, gatewayAvailable: false, gatewayRunning: true))
        XCTAssertFalse(
            MeshGate.isEnabled(
                mcpEnabled: true, gatewayAvailable: true, gatewayRunning: false))
    }

    func testResolvedStartCommandPrefersOwn() {
        let resolved = WorkspaceProtocolConfig.resolvedStartCommand(
            own: "claude --continue", fallback: "claude")
        XCTAssertEqual(resolved, "claude --continue")
    }

    func testResolvedStartCommandFallsBack() {
        let resolved = WorkspaceProtocolConfig.resolvedStartCommand(
            own: "  ", fallback: " claude ")
        XCTAssertEqual(resolved, "claude")
    }

    func testResolvedStartCommandEmptyMeansNil() {
        XCTAssertNil(WorkspaceProtocolConfig.resolvedStartCommand(own: nil, fallback: ""))
        XCTAssertNil(WorkspaceProtocolConfig.resolvedStartCommand(own: "", fallback: nil))
    }

    func testWorkspaceConfigDecodesAgentCli() throws {
        let config = try JSONDecoder().decode(
            WorkspaceConfig.self, from: Data(#"{"agentCli":"claude --continue"}"#.utf8))
        XCTAssertEqual(config.agentCli, "claude --continue")
        let empty = try JSONDecoder().decode(WorkspaceConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.agentCli, "")
    }

    func testProtocolEnabledDefaultsTrue() throws {
        let json = #"{"startCommand":"claude"}"#
        let config = try JSONDecoder().decode(
            WorkspaceProtocolConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.enabled)
        let disabled = try JSONDecoder().decode(
            WorkspaceProtocolConfig.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertFalse(disabled.enabled)
    }
}
