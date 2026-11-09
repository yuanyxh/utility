import XCTest
@testable import utility

final class ConfigDefaultsTests: XCTestCase {
    func testMissingConfigFallsBackToBundledTemplate() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-defaults-\(UUID().uuidString)", isDirectory: true)
        let config = ConfigManager.readConfigOrDefault(in: directory)
        XCTAssertEqual(config.mcp?.enabled, true)
    }
}
