import XCTest

@testable import utility

private final class FakeMeshClient: MeshClientProtocol, @unchecked Sendable {
    private(set) var registered: [MeshCard] = []
    private(set) var touched: [String] = []
    private(set) var deregistered: [String] = []
    let inboxRoot: String

    init(inboxRoot: String = "/tmp/mesh-inbox") {
        self.inboxRoot = inboxRoot
    }

    func register(_ card: MeshCard) async throws -> MeshCard {
        registered.append(card)
        var stored = card
        stored.endpoint = "\(inboxRoot)/\(card.id)"
        return stored
    }

    func touch(serviceID: String, status: String?) async throws {
        touched.append(serviceID)
    }

    func deregister(serviceID: String) async throws {
        deregistered.append(serviceID)
    }

    func list() async throws -> [MeshCard] { [] }
}

final class MeshCardTests: XCTestCase {
    func testDecodesGatewaySnakeCase() throws {
        let json = """
            {"id":"ws-1","name":"utility","kind":"workspace","owner_gateway":"gw-local",
             "transport":"directory","endpoint":"/tmp/inbox/ws-1","capabilities":["agent"],
             "status":"pending","start_command":"claude","startable":true}
            """
        let card = try JSONDecoder().decode(MeshCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.ownerGateway, "gw-local")
        XCTAssertEqual(card.startCommand, "claude")
        XCTAssertEqual(card.status, "pending")
        XCTAssertTrue(card.startable)
    }

    func testDecodesMissingOptionalFields() throws {
        let json = #"{"id":"ws-1","name":"a","endpoint":"ws-1"}"#
        let card = try JSONDecoder().decode(MeshCard.self, from: Data(json.utf8))
        XCTAssertNil(card.ownerGateway)
        XCTAssertFalse(card.startable)
        XCTAssertEqual(card.kind, "workspace")
    }
}

@MainActor
final class WorkspaceMeshCoordinatorTests: XCTestCase {
    private func makeWorkspace(id: String = "ws-1", startCommand: String? = nil) -> Workspace {
        Workspace(
            id: id,
            name: "utility",
            path: "/tmp",
            protocolConfig: WorkspaceProtocolConfig(startCommand: startCommand),
        )
    }

    func testSyncRegistersWorkspace() async {
        let fake = FakeMeshClient()
        let coordinator = WorkspaceMeshCoordinator { _ in fake }
        let registered = expectation(description: "registered")
        coordinator.onRegistered = { _, _ in registered.fulfill() }
        coordinator.sync(
            entries: [(makeWorkspace(), "offline", "claude")],
            port: 9001, enabled: true)
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertEqual(fake.registered.map(\.id), ["ws-1"])
        XCTAssertEqual(fake.registered.first?.startCommand, "claude")
        XCTAssertEqual(fake.registered.first?.status, "offline")
        XCTAssertTrue(fake.registered.first?.startable == true)
        coordinator.stop()
    }

    func testStatusChangeReregisters() async {
        let fake = FakeMeshClient()
        let coordinator = WorkspaceMeshCoordinator { _ in fake }
        let first = expectation(description: "first")
        coordinator.onRegistered = { _, _ in first.fulfill() }
        coordinator.sync(
            entries: [(makeWorkspace(), "offline", nil)], port: 9001, enabled: true)
        await fulfillment(of: [first], timeout: 1)
        coordinator.onRegistered = nil
        coordinator.sync(
            entries: [(makeWorkspace(), "ready", nil)], port: 9001, enabled: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.registered.map(\.status), ["offline", "ready"])
        coordinator.stop()
    }

    func testDisabledDoesNothing() {
        let fake = FakeMeshClient()
        let coordinator = WorkspaceMeshCoordinator { _ in fake }
        coordinator.sync(entries: [(makeWorkspace(), "ready", nil)], port: 9001, enabled: false)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(fake.registered.isEmpty)
    }

    func testRemovalDeregisters() async {
        let fake = FakeMeshClient()
        let coordinator = WorkspaceMeshCoordinator { _ in fake }
        let registered = expectation(description: "registered")
        coordinator.onRegistered = { _, _ in registered.fulfill() }
        coordinator.sync(entries: [(makeWorkspace(), "ready", nil)], port: 9001, enabled: true)
        await fulfillment(of: [registered], timeout: 1)
        coordinator.sync(entries: [], port: 9001, enabled: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.deregistered, ["ws-1"])
        coordinator.stop()
    }

    func testUsesProvidedStartCommand() async {
        let fake = FakeMeshClient()
        let coordinator = WorkspaceMeshCoordinator { _ in fake }
        let registered = expectation(description: "registered")
        coordinator.onRegistered = { _, _ in registered.fulfill() }
        coordinator.sync(
            entries: [(makeWorkspace(), "offline", "claude --continue")],
            port: 9001, enabled: true)
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertEqual(fake.registered.first?.startCommand, "claude --continue")
        XCTAssertTrue(fake.registered.first?.startable == true)
        coordinator.stop()
    }

    func testStartCommandChangeReregisters() async {
        let fake = FakeMeshClient()
        let coordinator = WorkspaceMeshCoordinator { _ in fake }
        let first = expectation(description: "first")
        coordinator.onRegistered = { _, _ in first.fulfill() }
        coordinator.sync(entries: [(makeWorkspace(), "ready", nil)], port: 9001, enabled: true)
        await fulfillment(of: [first], timeout: 1)
        coordinator.onRegistered = nil
        coordinator.sync(
            entries: [(makeWorkspace(), "ready", "claude")], port: 9001, enabled: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.registered.map(\.startCommand), [nil, "claude"])
        coordinator.stop()
    }
}

@MainActor
final class WorkspaceInboxWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "old".write(to: directory.appendingPathComponent("1-old.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testIgnoresExistingAndNotifiesNew() {
        let watcher = WorkspaceInboxWatcher()
        var received: [String] = []
        watcher.onMessage = { _, text in received.append(text) }
        watcher.setDirectories(["ws-1": directory])
        watcher.pollNow()
        XCTAssertTrue(received.isEmpty)

        try? "new".write(
            to: directory.appendingPathComponent("2-new.json"),
            atomically: true,
            encoding: .utf8,
        )
        watcher.pollNow()
        XCTAssertEqual(received, ["new"])
        watcher.pollNow()
        XCTAssertEqual(received, ["new"])
        watcher.stop()
    }
}
