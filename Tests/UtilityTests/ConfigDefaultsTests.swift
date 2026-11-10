import XCTest
@testable import utility

final class ConfigDefaultsTests: XCTestCase {
    func testMissingConfigFallsBackToBundledTemplate() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-defaults-\(UUID().uuidString)", isDirectory: true)
        let config = ConfigManager.readConfigOrDefault(in: directory)
        XCTAssertEqual(config.mcp?.enabled, true)
    }

    func testDecimalizedRewritesScientificFloatsOnly() {
        let input = [
            "hotkey: cmd+shift+c",
            "pollInterval: 3e-1",
            "aiTimeout: 1.2e+2",
            "rankSignalAccess: 0e+0",
            "note: \"keep 3e-1\"",
        ].joined(separator: "\n")
        let output = ConfigManager.decimalized(input)
        XCTAssertTrue(output.contains("pollInterval: 0.3"))
        XCTAssertTrue(output.contains("aiTimeout: 120"))
        XCTAssertTrue(output.contains("rankSignalAccess: 0"))
        XCTAssertTrue(output.contains(#"note: "keep 3e-1""#))
    }
}
