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

    /// 构建/缓存目录名单 —— 目录跳过与文件排除的**单一事实源**。
    ///
    /// 两处曾各持一份：目录遍历用本名单（15 项），文件过滤只看 `resolvedExcludes`
    /// （7 项、不含 `Utility.app`）。于是打包产物 `Utility.app/**` 里的 `.py`/`.swift`
    /// 全部按后缀命中 includes 而入库（实测 120 文件 / 5996 符号，占全库 75%），
    /// 检索结果里同一个符号恒出现两份。往 `resolvedExcludes` 补一条只能治当下，
    /// 两份名单迟早再次漂移，故收敛到此处。
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

    /// 路径中任一级目录命中跳过名单即为真。
    ///
    /// 文件事件只带自身路径（`isDir` 为假），若不查祖先目录，`Utility.app/x.py`
    /// 就绕过了目录级的跳过判定。
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
