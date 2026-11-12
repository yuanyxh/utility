import SQLite3
import XCTest
@testable import utility

final class ArchiveSchemaTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }

    func testSubsetSchemaIsAccepted() throws {
        let incoming = try makeDatabase(name: "incoming.sqlite", tables: ["neurons"])
        let current = try makeDatabase(name: "current.sqlite", tables: ["neurons", "synapses"])
        XCTAssertNoThrow(
            try ConfigArchive.checkSchema(
                incoming: incoming,
                current: current,
                path: "data/memory_graph.sqlite",
            ),
        )
    }

    func testExtraIncomingTableIsRejected() throws {
        let incoming = try makeDatabase(name: "incoming.sqlite", tables: ["neurons", "future"])
        let current = try makeDatabase(name: "current.sqlite", tables: ["neurons"])
        XCTAssertThrowsError(
            try ConfigArchive.checkSchema(
                incoming: incoming,
                current: current,
                path: "data/memory_graph.sqlite",
            ),
        ) { error in
            guard case ArchiveError.schemaMismatch(let path, let tables) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "data/memory_graph.sqlite")
            XCTAssertEqual(tables, ["future"])
        }
    }

    private func makeDatabase(name: String, tables: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw ArchiveError.invalidManifest("cannot open \(name)")
        }
        defer { sqlite3_close(handle) }
        for table in tables {
            let created = sqlite3_exec(
                handle, "CREATE TABLE \(table) (id INTEGER)", nil, nil, nil
            )
            guard created == SQLITE_OK else {
                throw ArchiveError.invalidManifest("cannot create \(table)")
            }
        }
        return url
    }
}
