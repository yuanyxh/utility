import Cocoa

/// Read-only line diff between the disk file and an unsaved buffer.
@MainActor
final class EditorDraftDiffWindow: NSWindowController {
    private static var current: EditorDraftDiffWindow?

    private static let addedColor = NSColor.systemGreen
    private static let removedColor = NSColor.systemRed

    static func present(title: String, name: String, diskText: String, localText: String) {
        current?.close()
        let controller = EditorDraftDiffWindow(
            title: "\(title) — \(name)", diskText: diskText, localText: localText,
        )
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(title: String, diskText: String, localText: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false,
        )
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        textView.isEditable = false
        textView.isRichText = true
        textView.font = VSTheme.editorFont(size: 12)
        textView.backgroundColor = VSTheme.editorBackground
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textStorage?.setAttributedString(attributedDiff(diskText, localText))

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        window.contentView = scrollView
        window.center()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    private func attributedDiff(_ diskText: String, _ localText: String) -> NSAttributedString {
        let font = VSTheme.editorFont(size: 12)
        let output = NSMutableAttributedString()
        let disk = diskText.components(separatedBy: "\n")
        let local = localText.components(separatedBy: "\n")
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in local.difference(from: disk) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var diskIndex = 0
        var localIndex = 0
        while diskIndex < disk.count || localIndex < local.count {
            if diskIndex < disk.count, removed.contains(diskIndex) {
                append("- \(disk[diskIndex])\n", color: Self.removedColor, font: font, to: output)
                diskIndex += 1
                continue
            }
            if localIndex < local.count, inserted.contains(localIndex) {
                append("+ \(local[localIndex])\n", color: Self.addedColor, font: font, to: output)
                localIndex += 1
                continue
            }
            if diskIndex < disk.count {
                append("  \(disk[diskIndex])\n", color: VSTheme.editorText, font: font, to: output)
                diskIndex += 1
            }
            if localIndex < local.count { localIndex += 1 }
        }
        return output
    }

    private func append(
        _ text: String, color: NSColor, font: NSFont, to output: NSMutableAttributedString,
    ) {
        output.append(
            NSAttributedString(
                string: text, attributes: [.foregroundColor: color, .font: font],
            ),
        )
    }
}
