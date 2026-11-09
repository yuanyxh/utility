import XCTest
@testable import utility

final class SetupProbeTests: XCTestCase {
    func testEmbedderDirectoryMatchesFastembedAlias() throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastembed-\(UUID().uuidString)", isDirectory: true)
        let alias = cache.appendingPathComponent("models--Qdrant--all-MiniLM-L6-v2-onnx")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: cache, resultingItemURL: nil) }

        var config = AppConfig()
        config.mcp = MCPConfig()
        config.mcp?.fastembedCacheDir = cache.path
        XCTAssertEqual(
            SetupProbe.embedderModelDirectory(config: config).lastPathComponent,
            "models--Qdrant--all-MiniLM-L6-v2-onnx",
        )
    }
}
