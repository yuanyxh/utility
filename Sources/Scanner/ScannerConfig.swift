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

    /// Returns true if a file with the given relative path should be processed.
    func shouldInclude(_ path: String) -> Bool {
        for excl in resolvedExcludes {
            if matchGlob(path, pattern: excl) { return false }
        }
        for incl in resolvedIncludes {
            if matchGlob(path, pattern: incl) { return true }
        }
        return false
    }

    /// Returns true if a directory name is a known build/cache dir to skip.
    func shouldSkipDirectory(_ name: String) -> Bool {
        let skipDirs: Set = [".build", "node_modules", "dist", ".git",
                             ".utility", "Pods", ".venv", "__pycache__",
                             ".svn", ".hg", ".gradle", "build", "DerivedData",
                             "Utility.app", "DerivedData"]
        return skipDirs.contains(name)
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
