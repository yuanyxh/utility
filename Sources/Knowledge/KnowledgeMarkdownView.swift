import Cocoa

/// Thin wrapper so the knowledge panel keeps its `render(_:)` entry point while
/// sharing the WebKit renderer with the workspace editor.
final class KnowledgeMarkdownView: NSView {
    private let preview = MarkdownPreviewView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder _: NSCoder) { nil }

    func render(_ markdown: String) {
        preview.render(markdown: markdown, baseURL: nil)
    }
}
