import Foundation

/// Scans a project directory, extracts symbols and package info,
/// writes to `.utility/deps.sqlite`.
final class ProjectScanner {
    static let shared = ProjectScanner()

    private var extractors: [String: SymbolExtractor] = [:]

    private init() {
        register(SwiftExtractor())
        register(JSTSExtractor())
        register(PythonExtractor())
        register(VueExtractor())
        register(JavaExtractor())
        register(KotlinExtractor())
    }

    func register(_ extractor: SymbolExtractor) {
        for ext in extractor.supportedExtensions {
            extractors[ext] = extractor
        }
    }

    /// Returns the extractor for a given file extension, or nil.
    func extractor(for ext: String) -> SymbolExtractor? {
        extractors[ext]
    }

    /// Full scan entry point. Clears existing DB, walks directory, extracts everything.
    /// - Parameter projectPath: Absolute path to the project root.
    /// - Throws: ScannerError or file system errors.
    func scan(projectPath: String) throws -> ScanSummary {
        let db = try ProjectDatabase(projectPath: projectPath)
        let config = ScannerConfig(projectPath: projectPath)

        // 不在扫描开始处清库：清空必须与写入同事务（见 `replaceScanResults`）。
        // 否则采集阶段（目录遍历 + 读文件 + AST 提取，大项目可达数十秒）里库是
        // 空的，期间任何检索工具都返回「什么都没有」。

        let fm = FileManager.default
        // Standardize the root URL's symlinks (e.g. /tmp → /private/tmp) and
        // later standardize each enumerator URL to match — standardizing BOTH
        // sides to the same form avoids mismatched path replacement.
        let rawRoot = URL(fileURLWithPath: projectPath)
        let rootURL = rawRoot.standardizedFileURL
        var fileCount = 0
        var symCount = 0
        var pkgCount = 0
        var failCount = 0

        // ── phase 1: walk directories ──
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles],
        ) else {
            throw ScannerError.cannotEnumerate(projectPath)
        }

        var dirMap: [String: DirectoryRecord] = [:]
        // 含清单文件的目录（相对路径）。遍历结束后统一回填到 dirMap：清单可能
        // 先于或后于其目录被枚举，父目录也可能由下面的惰性创建补出，就地标记
        // 会依赖枚举顺序。
        var manifestDirs: Set<String> = []
        var fileResults: [(FileRecord, String?)] = [] // (file, maybe content)

        for case let fileURL as URL in enumerator {
            let url = fileURL.standardizedFileURL
            let relPath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            // Skip excluded directories
            if isDir {
                let name = url.lastPathComponent
                if config.shouldSkipDirectory(name) {
                    enumerator.skipDescendants()
                    continue
                }
                // Record directory
                if !relPath.isEmpty {
                    let parent = (relPath as NSString).deletingLastPathComponent
                    dirMap[relPath] = DirectoryRecord(
                        path: relPath,
                        moduleName: name,
                        parentPath: parent.isEmpty ? nil : parent,
                        fileCount: 0,
                        // 清单标记在下面遇到清单文件时回填。此处若拿目录名去比对
                        // `isManifestFile` 那组文件名，恒为 false。
                        hasPackageManifest: false,
                    )
                }
                continue
            }

            // 清单判定必须在 includes 过滤**之前**：package.json / pyproject.toml
            // / Podfile / build.gradle 都不匹配任何 include 模式（includes 只列了
            // 源码扩展名），放到过滤后面就永远标不上模块根。
            // 根目录下的清单无处可标（根目录本身不写进 directories），跳过即可。
            if Self.isManifestFile(url.lastPathComponent) {
                let dirPath = (relPath as NSString).deletingLastPathComponent
                if !dirPath.isEmpty { manifestDirs.insert(dirPath) }
            }

            // Skip files not matching includes
            guard config.shouldInclude(relPath) else { continue }

            let ext = url.pathExtension.lowercased()
            let parentPath = (relPath as NSString).deletingLastPathComponent

            // Read file content for symbol extraction (regex or AST)
            var content: String? = nil
            if extractors[ext] != nil || ASTExtractorRunner.isSupported(ext) {
                content = try? String(contentsOf: url, encoding: .utf8)
            }

            fileResults.append((FileRecord(
                path: relPath,
                dirPath: parentPath,
                name: url.lastPathComponent,
                ext: ext,
                symCount: 0,
            ), content))

            // Update directory file count
            if var dir = dirMap[parentPath] {
                dir.fileCount += 1
                dirMap[parentPath] = dir
            } else if parentPath.isEmpty {
                // Root-level file
            } else {
                // Lazily create parent dir if not yet recorded
                let parts = parentPath.components(separatedBy: "/")
                var acc = ""
                for part in parts {
                    if !acc.isEmpty { acc += "/" }
                    acc += part
                    if dirMap[acc] == nil {
                        dirMap[acc] = DirectoryRecord(path: acc, moduleName: part, parentPath: nil, fileCount: 0, hasPackageManifest: false)
                    }
                }
                if var dir = dirMap[parentPath] {
                    dir.fileCount += 1
                    dirMap[parentPath] = dir
                }
            }

            fileCount += 1
        }

        // 回填模块根标记。统一放到遍历结束后做，不依赖枚举顺序。
        for dirPath in manifestDirs {
            if var dir = dirMap[dirPath] {
                dir.hasPackageManifest = true
                dirMap[dirPath] = dir
            }
        }

        // 目录不在此处落库：与文件、符号一起进 `replaceScanResults` 的单事务，
        // 否则库会停在「目录已写、符号未写」的不一致态。
        // ── phase 2: extract symbols concurrently ──
        let totalFiles = fileResults.count

        // Pre-read failed counts & prepare batch AST inputs
        var failedCounts: [String: Int] = [:]
        var astBatchInputs: [ASTExtractorRunner.BatchInput] = []
        for (fileRec, maybeContent) in fileResults {
            guard let content = maybeContent, ASTExtractorRunner.isSupported(fileRec.ext) else { continue }
            let fails = (try? db.failedFileCount(path: fileRec.path)) ?? 0
            failedCounts[fileRec.path] = fails
            if fails < 3 {
                astBatchInputs.append(ASTExtractorRunner.BatchInput(
                    content: content, filePath: fileRec.path, ext: fileRec.ext,
                ))
            }
        }

        // Batch AST extraction (single subprocess call for all files)
        let batchASTResults = ASTExtractorRunner.extractBatch(astBatchInputs)

        let extractLock = NSLock()
        var results: [Int: (file: FileRecord, symbols: [SymbolRecord], astFailed: Bool)] = [:]

        if totalFiles > 0 {
            DispatchQueue.concurrentPerform(iterations: totalFiles) { i in
                let (fileRec, maybeContent) = fileResults[i]
                guard let content = maybeContent else {
                    extractLock.lock()
                    results[i] = (fileRec, [], false)
                    extractLock.unlock()
                    return
                }

                let ext = fileRec.ext
                let regexExtractor = extractors[ext]
                var symbols: [SymbolRecord] = []
                var astFailed = false

                // Priority 1: AST pipeline (batch results)
                if ASTExtractorRunner.isSupported(ext) {
                    let prevFails = failedCounts[fileRec.path] ?? 3
                    if prevFails < 3 {
                        if let batchSymbols = batchASTResults[fileRec.path] {
                            symbols = batchSymbols
                        } else {
                            astFailed = true
                        }
                    }
                }

                // Priority 2: regex fallback
                if symbols.isEmpty, let regexExtractor {
                    symbols = regexExtractor.extract(from: content, filePath: fileRec.path)
                    if !symbols.isEmpty {
                        astFailed = false
                    }
                }

                extractLock.lock()
                results[i] = (fileRec.withSymCount(symbols.count), symbols, astFailed)
                extractLock.unlock()
            }
        }

        // ── parse manifests（纯读，先算完再进写事务）──
        let packages = ManifestParser.parseAll(in: projectPath).flatMap(\.packages)
        pkgCount = packages.count

        // ── phase 3: 原子替换 ──
        // 清空、写入与 FTS 重建在同一事务内完成，读者看不到空库或半成品。
        try db.replaceScanResults(
            directories: Array(dirMap.values),
            files: (0 ..< totalFiles).compactMap { results[$0] },
            packages: packages,
        )

        symCount = results.values.reduce(0) { $0 + $1.symbols.count }
        failCount = results.values.count(where: { $0.astFailed })

        // Clear failed_files entries for files that no longer exist in the project
        try db.pruneFailedFiles(knownPaths: Set(fileResults.map(\.0.path)))

        return ScanSummary(
            files: fileCount,
            symbols: symCount,
            packages: pkgCount,
            failed: failCount,
        )
    }

    private static func isManifestFile(_ name: String) -> Bool {
        let manifests: Set = ["Package.swift", "package.json",
                              "pyproject.toml", "Podfile", "build.gradle"]
        return manifests.contains(name)
    }
}

// MARK: - Types

struct ScanSummary: CustomStringConvertible {
    let files: Int
    let symbols: Int
    let packages: Int
    let failed: Int

    var description: String {
        "Found: \(files) files, \(symbols) symbols, \(packages) packages\(failed > 0 ? ", \(failed) failed" : "")"
    }
}

enum ScannerError: Error, LocalizedError {
    case cannotEnumerate(String)

    var errorDescription: String? {
        switch self {
        case let .cannotEnumerate(path):
            "Cannot enumerate directory: \(path)"
        }
    }
}
