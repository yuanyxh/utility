import XCTest

@testable import utility

final class FileTreeScannerTests: XCTestCase {
    func testSymlinkEntriesAreListedAndCountIsCycleSafe() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("filetree-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(
            to: target.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8,
        )

        try fm.createSymbolicLink(
            at: root.appendingPathComponent("file-link"),
            withDestinationURL: target.appendingPathComponent("note.txt"),
        )
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("dir-link"), withDestinationURL: target,
        )
        try fm.createSymbolicLink(
            at: target.appendingPathComponent("back"), withDestinationURL: root,
        )

        let result = FileTreeScanner.children(of: root, showHidden: true, extraIgnores: [])
        let byName = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.name, $0) })
        XCTAssertEqual(byName["file-link"]?.isSymlink, true)
        XCTAssertEqual(byName["file-link"]?.isDirectory, false)
        XCTAssertEqual(byName["dir-link"]?.isSymlink, true)
        XCTAssertEqual(byName["dir-link"]?.isDirectory, true)
        XCTAssertEqual(byName["target"]?.isSymlink, false)
        XCTAssertEqual(byName["target"]?.isDirectory, true)

        let linkChildren = FileTreeScanner.children(
            of: root.appendingPathComponent("dir-link"), showHidden: true, extraIgnores: [],
        )
        XCTAssertEqual(linkChildren.nodes.map(\.name).sorted(), ["back", "note.txt"])

        let count = FileTreeScanner.countFiles(at: root, showHidden: true, extraIgnores: [])
        XCTAssertEqual(count, 2)
    }
}
