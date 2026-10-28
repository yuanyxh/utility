import Cocoa
import SwiftTerm

/// Terminal that inserts shell-quoted file paths dropped from Finder.
final class TerminalDropView: LocalProcessTerminalView {
    private static let unsafeCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "'\"\\$`!*?[]{}()&;|<>#~^="))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = fileURLs(from: sender).map(\.path)
        guard !paths.isEmpty, process != nil else { return false }
        let text = paths.map(shellPath).joined(separator: " ") + " "
        send(source: self, data: ArraySlice(Array(text.utf8)))
        window?.makeFirstResponder(self)
        return true
    }

    /// Quote only paths with shell-special characters.
    private func shellPath(_ path: String) -> String {
        path.unicodeScalars.contains(where: Self.unsafeCharacters.contains)
            ? TerminalShell.quote(path) : path
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options,
        )
        return (objects as? [NSURL])?.map { $0 as URL } ?? []
    }
}
