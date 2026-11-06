import Foundation

/// Matches a relative path against git-ignored paths, including ancestors.
struct IgnoreRules: Equatable {
    static let empty = IgnoreRules()

    private let paths: Set<String>

    init(paths: Set<String> = []) {
        self.paths = paths
    }

    func isIgnored(relativePath: String) -> Bool {
        guard !paths.isEmpty else { return false }
        var candidate = relativePath
        while !candidate.isEmpty {
            if paths.contains(candidate) { return true }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { return false }
            candidate = parent
        }
        return false
    }
}
