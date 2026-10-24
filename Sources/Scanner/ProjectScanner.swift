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

        // Do not clear the DB at the start of a scan: clearing must be in the same transaction as the writes (see `replaceScanResults`).
        // Otherwise during the collection phase (directory traversal + file reads + AST extraction, which can take tens of
        // seconds for large projects) the DB is empty, and any search tool during that time returns "nothing at all".

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
        // Directories containing manifest files (relative paths). Backfilled into dirMap uniformly after traversal ends:
        // a manifest may be enumerated before or after its directory, and parent directories may also be supplied by the
        // lazy creation below, so marking in place would depend on enumeration order.
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
                        // The manifest flag is backfilled below when a manifest file is encountered. Comparing a directory name
                        // against the `isManifestFile` set of filenames here would always be false.
                        hasPackageManifest: false,
                    )
                }
                continue
            }

            // The manifest check must come **before** the includes filter: package.json / pyproject.toml
            // / Podfile / build.gradle do not match any include pattern (includes lists only source
            // extensions), so placing it after the filter would never mark the module root.
            // A manifest directly under the root has nowhere to be marked (the root itself is not written into
            // directories), so it is fine to skip it.
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

        // Backfill the module root flag. Uniformly done after traversal ends, not dependent on enumeration order.
        for dirPath in manifestDirs {
            if var dir = dirMap[dirPath] {
                dir.hasPackageManifest = true
                dirMap[dirPath] = dir
            }
        }

        // Directories are not persisted here: they go with files and symbols into the single transaction of
        // `replaceScanResults`, otherwise the DB would stop in an inconsistent "directories written, symbols not yet" state.
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
        let batchASTResults = ASTExtractorRunner.extractBatchWithImports(astBatchInputs)

        let extractLock = NSLock()
        var results: [Int: (file: FileRecord, symbols: [SymbolRecord], imports: [ImportRecord], astFailed: Bool)] = [:]

        if totalFiles > 0 {
            DispatchQueue.concurrentPerform(iterations: totalFiles) { i in
                let (fileRec, maybeContent) = fileResults[i]
                guard let content = maybeContent else {
                    extractLock.lock()
                    results[i] = (fileRec, [], [], false)
                    extractLock.unlock()
                    return
                }

                let ext = fileRec.ext
                let regexExtractor = extractors[ext]
                var symbols: [SymbolRecord] = []
                var imports: [ImportRecord] = []
                var astFailed = false
                var astSucceeded = false

                // Priority 1: AST pipeline (batch results). Key presence means the
                // parser succeeded even when the file only contains imports.
                if ASTExtractorRunner.isSupported(ext) {
                    let prevFails = failedCounts[fileRec.path] ?? 3
                    if prevFails < 3 {
                        if let ast = batchASTResults[fileRec.path] {
                            symbols = ast.symbols
                            imports = ast.imports
                            astSucceeded = true
                        } else {
                            astFailed = true
                        }
                    }
                }

                // Priority 2: regex fallback for symbols
                if symbols.isEmpty, let regexExtractor {
                    symbols = regexExtractor.extract(from: content, filePath: fileRec.path)
                    if !symbols.isEmpty {
                        astFailed = false
                    }
                }

                // Imports fall back to regex only when the AST pipeline did not run.
                if !astSucceeded, let regexExtractor {
                    imports = regexExtractor.imports(from: content, filePath: fileRec.path)
                }

                extractLock.lock()
                results[i] = (fileRec.withSymCount(symbols.count), symbols, imports, astFailed)
                extractLock.unlock()
            }
        }

        // ── parse manifests (read-only, computed fully before entering the write transaction) ──
        let packages = ManifestParser.parseAll(in: projectPath).flatMap(\.packages)
        pkgCount = packages.count

        // ── phase 3: atomic replacement ──
        // Clearing, writing, and FTS rebuild are done in the same transaction; readers never see an empty DB or a half-finished one.
        let context = ResolutionContextBuilder.make(
            projectPath: projectPath,
            filePaths: Set(fileResults.map(\.0.path)),
            manifestDirs: manifestDirs,
        )
        let resolvedImports = ImportResolverRegistry.resolveAll(
            results.values.flatMap(\.imports), context: context,
        )
        try db.replaceScanResults(
            directories: Array(dirMap.values),
            files: (0 ..< totalFiles).compactMap { i in
                results[i].map {
                    (file: $0.file, symbols: $0.symbols, astFailed: $0.astFailed)
                }
            },
            packages: packages,
            imports: resolvedImports,
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
