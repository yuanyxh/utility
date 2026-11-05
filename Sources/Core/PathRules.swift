import Foundation

/// Build/cache directory names shared by the project scanner and the workspace file tree.
///
/// Files inside these directories must never be listed or indexed; keeping one list
/// prevents the scanner and the explorer from drifting apart.
enum PathRules {
    static let skippedDirNames: Set<String> = [
        ".build", "node_modules", "dist", ".git", ".agent-gateway", ".utility",
        "Pods", ".venv", "__pycache__", ".svn", ".hg", ".gradle", "build",
        "DerivedData", "Utility.app", ".next",
    ]

    static func shouldSkip(name: String) -> Bool {
        skippedDirNames.contains(name)
    }

    /// Noise files hidden even when dotfiles are shown.
    static let alwaysHiddenFileNames: Set<String> = [".DS_Store", ".localized"]

    static func isAlwaysHiddenFile(name: String) -> Bool {
        alwaysHiddenFileNames.contains(name)
    }

    /// True when any path segment hits the skip list.
    ///
    /// File events carry only their own path (`isDir` false); without checking
    /// ancestor directories, `Utility.app/x.py` would bypass the directory-level
    /// skip check.
    static func containsSkippedDir(_ path: String) -> Bool {
        // The last segment is the file or directory itself, not an ancestor.
        path.split(separator: "/").dropLast().contains { shouldSkip(name: String($0)) }
    }
}
