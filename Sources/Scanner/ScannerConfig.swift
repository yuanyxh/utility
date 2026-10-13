import Foundation

/// Loads `.utility/config.json` from the project root.
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
        let configPath = (projectPath as NSString).appendingPathComponent(".utility/config.json")

        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let decoded = try? JSONDecoder().decode(Config.self, from: data)
        {
            config = decoded
        } else {
            config = Config()
        }

        resolvedIncludes = config.includes ?? ["**/*.swift", "**/*.ts", "**/*.tsx", "**/*.js",
                                               "**/*.jsx", "**/*.vue", "**/*.mjs", "**/*.cjs",
                                               "**/*.py",
                                               "**/*.java", "**/*.kt", "**/*.m", "**/*.h"]
        resolvedExcludes = config.excludes ?? [".build/**", "node_modules/**", "dist/**",
                                               ".git/**", ".utility/**", "Pods/**", ".venv/**"]
    }

    /// Build/cache directory names — the **single source of truth** for both
    /// directory skipping and file exclusion.
    ///
    /// These were once kept in two places: directory traversal used this list
    /// (15 entries), while file filtering only consulted `resolvedExcludes`
    /// (7 entries, missing `Utility.app`). As a result every `.py`/`.swift`
    /// inside the packaging output `Utility.app/**` matched includes by
    /// extension and got indexed (measured: 120 files / 5996 symbols, 75% of
    /// the whole DB), so the same symbol appeared twice in search results.
    /// Adding one entry to `resolvedExcludes` only fixes the moment; the two
    /// lists would drift again, so they are consolidated here.
    static let skippedDirNames: Set<String> = [
        ".build", "node_modules", "dist", ".git", ".utility", "Pods", ".venv",
        "__pycache__", ".svn", ".hg", ".gradle", "build", "DerivedData", "Utility.app",
    ]

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
        path.split(separator: "/").contains { Self.skippedDirNames.contains(String($0)) }
    }

    /// Returns true if a directory name is a known build/cache dir to skip.
    func shouldSkipDirectory(_ name: String) -> Bool {
        Self.skippedDirNames.contains(name)
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
