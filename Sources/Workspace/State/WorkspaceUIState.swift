import Foundation

enum ListMode: String, Codable, Sendable {
    case files
    case git
}

enum EditorPreviewMode: String, Codable, Sendable {
    case source
    case markdown
    case image
}

/// UI state that survives a restart; selections and undo stacks stay in memory.
struct WorkspaceUIState: Codable, Equatable, Sendable {
    static let maxExpandedPaths = 2000

    var activeList: ListMode
    var expandedPaths: [String]
    var caretLocation: Int
    var scrollY: Double
    var previewMode: EditorPreviewMode

    init(
        activeList: ListMode = .files,
        expandedPaths: [String] = [],
        caretLocation: Int = 0,
        scrollY: Double = 0,
        previewMode: EditorPreviewMode = .source,
    ) {
        self.activeList = activeList
        self.expandedPaths = expandedPaths
        self.caretLocation = caretLocation
        self.scrollY = scrollY
        self.previewMode = previewMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeList = (try? c.decodeIfPresent(ListMode.self, forKey: .activeList)) ?? .files
        expandedPaths = (try? c.decodeIfPresent([String].self, forKey: .expandedPaths)) ?? []
        caretLocation = (try? c.decodeIfPresent(Int.self, forKey: .caretLocation)) ?? 0
        scrollY = (try? c.decodeIfPresent(Double.self, forKey: .scrollY)) ?? 0
        previewMode =
            (try? c.decodeIfPresent(EditorPreviewMode.self, forKey: .previewMode)) ?? .source
    }

    /// Drops the oldest expanded paths and clamps editor positions to the loaded content.
    func clamped(textLength: Int, contentHeight: Double) -> WorkspaceUIState {
        var copy = self
        if copy.expandedPaths.count > Self.maxExpandedPaths {
            copy.expandedPaths.removeFirst(copy.expandedPaths.count - Self.maxExpandedPaths)
        }
        copy.caretLocation = min(max(copy.caretLocation, 0), max(textLength, 0))
        copy.scrollY = min(max(copy.scrollY, 0), max(contentHeight, 0))
        return copy
    }
}
