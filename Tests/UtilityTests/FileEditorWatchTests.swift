import Cocoa
import XCTest

@testable import utility

@MainActor
final class FileEditorWatchTests: XCTestCase {
    func testExternalAtomicWriteReloadsCleanDocument() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("editor-watch-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let url = root.appendingPathComponent("note.md")
        try "initial\n".write(to: url, atomically: true, encoding: .utf8)

        let pane = FileEditorPane(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        pane.open(url: url, root: root)
        XCTAssertTrue(waitUntil { pane.document != nil })
        XCTAssertEqual(pane.document?.text, "initial\n")

        try "changed by agent\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { pane.document?.text == "changed by agent\n" })
        pane.close()
    }

    func testWatchRecoversAfterDeleteAndRecreate() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("editor-recreate-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let url = root.appendingPathComponent("note.md")
        try "initial\n".write(to: url, atomically: true, encoding: .utf8)

        let pane = FileEditorPane(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        pane.open(url: url, root: root)
        XCTAssertTrue(waitUntil { pane.document != nil })

        try fm.removeItem(at: url)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        try "recreated\n".write(to: url, atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        try "final\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(waitUntil { pane.document?.text == "final\n" })
        pane.close()
    }

    func testSavingSymlinkWritesTargetAndKeepsLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("editor-link-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("target.txt")
        try "before\n".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        guard case .text(let document) = FileDocument.load(url: link, maxBytes: 1 << 20)
        else { return XCTFail("expected text document") }
        document.updateText("after\n")
        try document.save(overwriteExternal: false)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "after\n")
        let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(
            URL(fileURLWithPath: destination).standardizedFileURL,
            target.standardizedFileURL,
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: () -> Bool,
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
