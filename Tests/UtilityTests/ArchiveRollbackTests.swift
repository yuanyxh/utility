import XCTest
@testable import utility

final class ArchiveRollbackTests: XCTestCase {
    private var root: URL!
    private var configDir: URL!
    private var staging: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configDir = root.appendingPathComponent("config")
        staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("config"),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "old".write(
            to: configDir.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8,
        )
        try "new".write(
            to: staging.appendingPathComponent("config/config.yaml"),
            atomically: true,
            encoding: .utf8,
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }

    func testExternalFailureRollsBackCopiedFiles() throws {
        let notesDir = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try "old-ok".write(
            to: notesDir.appendingPathComponent("ok.md"),
            atomically: true,
            encoding: .utf8,
        )
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("external-notes"),
            withIntermediateDirectories: true,
        )
        try "note".write(
            to: staging.appendingPathComponent("external-notes/ok.md"),
            atomically: true,
            encoding: .utf8,
        )
        let blocker = root.appendingPathComponent("blocked")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("external-rss"),
            withIntermediateDirectories: true,
        )
        try "feed".write(
            to: staging.appendingPathComponent("external-rss/rss.md"),
            atomically: true,
            encoding: .utf8,
        )

        let plan = makePlan(
            external: [
                ExternalDir(
                    role: .notes,
                    originalPath: notesDir.path,
                    archivePath: "external-notes",
                    fileCount: 1,
                    bytes: 4,
                ),
                ExternalDir(
                    role: .rss,
                    originalPath: blocker.path,
                    archivePath: "external-rss",
                    fileCount: 1,
                    bytes: 4,
                ),
            ]
        )
        let decisions = [
            ExternalRestoreDecision(role: .notes, destination: notesDir, policy: .overwrite),
            ExternalRestoreDecision(role: .rss, destination: blocker, policy: .skipExisting),
        ]
        let backup = try ConfigArchive.applyCore(plan, configDir: configDir)

        XCTAssertThrowsError(
            try ConfigArchive.applyExternal(decisions: decisions, plan: plan, backup: backup)
        )
        let restored = try String(
            contentsOf: notesDir.appendingPathComponent("ok.md"),
            encoding: .utf8,
        )
        XCTAssertEqual(restored, "old-ok")
    }

    func testCoreRestoresAfterExternalFailure() throws {
        let blocker = root.appendingPathComponent("blocked")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("external-rss"),
            withIntermediateDirectories: true,
        )
        try "feed".write(
            to: staging.appendingPathComponent("external-rss/rss.md"),
            atomically: true,
            encoding: .utf8,
        )
        let plan = makePlan(
            external: [
                ExternalDir(
                    role: .rss,
                    originalPath: blocker.path,
                    archivePath: "external-rss",
                    fileCount: 1,
                    bytes: 4,
                )
            ]
        )
        let decisions = [
            ExternalRestoreDecision(role: .rss, destination: blocker, policy: .skipExisting)
        ]
        let backup = try ConfigArchive.applyCore(plan, configDir: configDir)
        XCTAssertEqual(try read("config.yaml"), "new")

        XCTAssertThrowsError(
            try ConfigArchive.applyExternal(decisions: decisions, plan: plan, backup: backup)
        )
        try ConfigArchive.rollbackCore(backup: backup, configDir: configDir, plan: plan)
        XCTAssertEqual(try read("config.yaml"), "old")
    }

    func testCoreRollbackRemovesFilesThatWereNotBackedUp() throws {
        try "extra".write(
            to: staging.appendingPathComponent("config/extra.yaml"),
            atomically: true,
            encoding: .utf8,
        )
        let files = [
            ArchiveFile(path: "config/config.yaml", sha256: "", bytes: 3),
            ArchiveFile(path: "config/extra.yaml", sha256: "", bytes: 5),
        ]
        let plan = makePlan(external: [], files: files)
        let backup = try ConfigArchive.applyCore(plan, configDir: configDir)
        let extra = configDir.appendingPathComponent("extra.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))

        try ConfigArchive.rollbackCore(backup: backup, configDir: configDir, plan: plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra.path))
        XCTAssertEqual(try read("config.yaml"), "old")
    }

    private func makePlan(
        external: [ExternalDir],
        files: [ArchiveFile] = [
            ArchiveFile(path: "config/config.yaml", sha256: "", bytes: 3)
        ],
    ) -> ArchiveImportPlan {
        let manifest = ArchiveManifest(
            formatVersion: 1,
            appVersion: "test",
            gatewayWheel: nil,
            createdAt: "2026-11-09",
            includesSecrets: false,
            scope: [],
            files: files,
            external: external,
            sourcePaths: [:],
        )
        return ArchiveImportPlan(stagingDir: staging, manifest: manifest, files: files)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: configDir.appendingPathComponent(name), encoding: .utf8)
    }
}
