import Cocoa

/// Split view with a themed divider and per-pane minimum sizes.
@MainActor
final class WorkspaceSplitView: NSSplitView {
    private let minimums: [CGFloat]

    init(isVertical: Bool, minimums: [CGFloat]) {
        self.minimums = minimums
        super.init(frame: .zero)
        self.isVertical = isVertical
        dividerStyle = .thin
        autoresizingMask = [.width, .height]
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var dividerThickness: CGFloat { 1 }

    override var dividerColor: NSColor { VSTheme.separator }

    func constrainedMin(_ proposed: CGFloat, at dividerIndex: Int) -> CGFloat {
        guard minimums.indices.contains(dividerIndex),
            subviews.indices.contains(dividerIndex)
        else { return proposed }
        let origin = start(of: subviews[dividerIndex].frame)
        return max(proposed, origin + minimums[dividerIndex])
    }

    func constrainedMax(_ proposed: CGFloat, at dividerIndex: Int) -> CGFloat {
        let next = dividerIndex + 1
        guard minimums.indices.contains(next), subviews.indices.contains(next) else {
            return proposed
        }
        let end = start(of: subviews[next].frame) + length(of: subviews[next].frame)
        return min(proposed, end - minimums[next])
    }

    private func start(of rect: NSRect) -> CGFloat {
        isVertical ? rect.minX : rect.minY
    }

    private func length(of rect: NSRect) -> CGFloat {
        isVertical ? rect.width : rect.height
    }
}
