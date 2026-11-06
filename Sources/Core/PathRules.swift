import Foundation

/// Directory names hidden from the workspace file tree and project scanner.
///
/// Only VCS metadata is skipped; build outputs and app bundles stay visible.
enum PathRules {
    static let skippedDirNames: Set<String> = [".git", ".svn"]

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
    /// ancestor directories, `.git/x.py` would bypass the directory-level skip.
    static func containsSkippedDir(_ path: String) -> Bool {
        // The last segment is the file or directory itself, not an ancestor.
        path.split(separator: "/").dropLast().contains { shouldSkip(name: String($0)) }
    }
}
