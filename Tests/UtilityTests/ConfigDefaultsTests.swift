import XCTest
@testable import utility

final class ConfigDefaultsTests: XCTestCase {
    func testMissingConfigFallsBackToBundledTemplate() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-defaults-\(UUID().uuidString)", isDirectory: true)
        let config = ConfigManager.readConfigOrDefault(in: directory)
        XCTAssertEqual(config.mcp?.enabled, true)
    }

    func testBrainConfigDefaultsAndOverrides() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let yaml = """
            mcp:
              brain:
                pairMode: v2
                sparseFloor: 0.1
                replay: false
            """
        try yaml.write(
            to: directory.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let config = ConfigManager.readConfigOrDefault(in: directory)
        XCTAssertEqual(config.mcp?.brain.pairMode, "v2")
        XCTAssertEqual(config.mcp?.brain.sparseFloor, 0.1)
        XCTAssertEqual(config.mcp?.brain.replay, false)
        XCTAssertEqual(config.mcp?.brain.attractor, true)
    }

    func testNestedNeuronConfigOverridesDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-neuron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let yaml = """
            mcp:
              neuron:
                maxDepth: 7
                reviewConcurrency: 9
            """
        try yaml.write(
            to: directory.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let config = ConfigManager.readConfigOrDefault(in: directory)
        XCTAssertEqual(config.mcp?.neuron.maxDepth, 7)
        XCTAssertEqual(config.mcp?.neuron.reviewConcurrency, 9)
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

    func testWriteWithBackupKeepsPreviousFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let file = directory.appendingPathComponent("config.yaml")
        try "a: 1\n".write(to: file, atomically: true, encoding: .utf8)

        try ConfigManager.writeWithBackup("a: 2\n", to: file)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a: 2\n")
        let backup = directory.appendingPathComponent("config.yaml.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "a: 1\n")
    }

    func testMergedWithTemplateCountsLeafKeys() {
        let original: [String: Any] = ["mcp": ["enabled": true]]
        let template: [String: Any] = [
            "mcp": [
                "enabled": true,
                "neuron": ["beam": 4, "brain": ["replay": true]],
                "memoryGovernanceApply": false,
            ],
            "general": ["httpTimeout": 30.0],
        ]

        let merged = ConfigManager.mergedWithTemplate(original, template)

        XCTAssertEqual(
            merged.added.sorted(),
            [
                "general.httpTimeout",
                "mcp.memoryGovernanceApply",
                "mcp.neuron.beam",
                "mcp.neuron.brain.replay",
            ]
        )
        XCTAssertEqual(merged.value["general"] as? [String: Any] != nil, true)
    }
}
