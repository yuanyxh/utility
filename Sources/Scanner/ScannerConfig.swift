import Foundation

/// Loads `.agent-gateway/config.json` from the project root (legacy `.utility/config.json` fallback).
final class ScannerConfig {
    struct Config: Codable {
        var includes: [String]?
        var excludes: [String]?
    }

    let config: Config
    let projectPath: String

    /// `includes` defaults to common source extensions.
    let resolvedIncludes: [String]
    /// `excludes` defaults to build/cache dirs.
    let resolvedExcludes: [String]

    init(projectPath: String) {
        self.projectPath = projectPath
        let current = (projectPath as NSString).appendingPathComponent(".agent-gateway/config.json")
        let legacy = (projectPath as NSString).appendingPathComponent(".utility/config.json")
        let configPath = FileManager.default.fileExists(atPath: current) ? current : legacy

        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
            let decoded = try? JSONDecoder().decode(Config.self, from: data)
        {
            config = decoded
        } else {
            config = Config()
        }

        resolvedIncludes =
            config.includes ?? [
                "**/*.swift", "**/*.ts", "**/*.tsx", "**/*.js",
                "**/*.jsx", "**/*.vue", "**/*.mjs", "**/*.cjs",
                "**/*.py",
                "**/*.java", "**/*.kt", "**/*.kts", "**/*.m", "**/*.h",
            ]
        resolvedExcludes =
            config.excludes ?? [
                ".build/**", "build/**", "dist/**", "DerivedData/**",
                "node_modules/**", "coverage/**", "__pycache__/**",
                "Utility.app/**", ".git/**", ".agent-gateway/**", ".utility/**",
                "Pods/**", ".venv/**",
            ]
    }

    /// Directory names pruned before traversal. Only VCS metadata is pruned;
    /// build outputs are excluded at file level by `resolvedExcludes` so the
    /// file tree can still show them. Indexing `Utility.app` once added
    /// 120 files / 5996 symbols (75% of the DB), hence its exclude entry.
    static let skippedDirNames: Set<String> = PathRules.skippedDirNames

    /// Returns true if a file with the given relative path should be processed.
    func shouldInclude(_ path: String) -> Bool {
        if containsSkippedDir(path) { return false }
        for excl in resolvedExcludes {
            if matchGlob(path, pattern: excl) { return false }
        }
        for incl in resolvedIncludes {
            if matchGlob(path, pattern: incl) { return true }
        }
        return false
    }

    /// True when any path segment hits the skip list.
    ///
    /// File events carry only their own path (`isDir` false); without checking
    /// ancestor directories, `Utility.app/x.py` would bypass the directory-level
    /// skip check.
    private func containsSkippedDir(_ path: String) -> Bool {
        PathRules.containsSkippedDir(path)
    }

    /// Returns true if a directory name is a known build/cache dir to skip.
    func shouldSkipDirectory(_ name: String) -> Bool {
        PathRules.shouldSkip(name: name)
    }

    private func matchGlob(_ path: String, pattern: String) -> Bool {
        // **/*.swift → suffix .swift
        if pattern.hasPrefix("**/*") {
            let ext = String(pattern.dropFirst(4))
            return path.hasSuffix(ext)
        }
        // .build/** → prefix .build/
        if pattern.hasSuffix("/**") {
            let prefix = String(pattern.dropLast(3))
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        // exact match
        return path == pattern
    }
}
