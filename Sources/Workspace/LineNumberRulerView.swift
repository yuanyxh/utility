import Cocoa

/// Gutter that draws logical line numbers for the visible glyph range only.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView? = nil
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func rebuildLineStarts(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        lineStarts = starts
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        VSTheme.gutterBackground.setFill()
        bounds.fill()

        guard let textView, let layoutManager = textView.layoutManager,
            let container = textView.textContainer, let scrollView
        else { return }
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: VSTheme.gutterText,
        ]

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            fragmentRect, _, _, fragmentGlyphRange, _ in
            let charRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange, actualGlyphRange: nil,
            )
            let index = self.lineIndex(at: charRange.location)
            guard index < self.lineStarts.count,
                self.lineStarts[index] == charRange.location
            else { return }

            var rect = self.convert(fragmentRect, from: textView)
            rect.origin.y += textView.textContainerInset.height
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: self.ruleThickness - size.width - 6, y: rect.minY),
                withAttributes: attributes,
            )
        }
    }

    private func lineIndex(at characterIndex: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characterIndex {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
