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

        // Clear previous scan
        try db.clearAll()

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
            options: [.skipsHiddenFiles]
        ) else {
            throw ScannerError.cannotEnumerate(projectPath)
        }

        var dirMap: [String: DirectoryRecord] = [:]
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
                    let hasManifest = Self.isManifestFile(name)
                    dirMap[relPath] = DirectoryRecord(
                        path: relPath,
                        moduleName: name,
                        parentPath: parent.isEmpty ? nil : parent,
                        fileCount: 0,
                        hasPackageManifest: hasManifest
                    )
                }
                continue
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
                symCount: 0
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

        // ── write directories ──
        for dir in dirMap.values {
            try db.insertDirectory(dir)
        }

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
                    content: content, filePath: fileRec.path, ext: fileRec.ext
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
                if symbols.isEmpty, let regexExtractor = regexExtractor {
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

        // ── phase 3: batch write ──
        try db.batchWriteFiles((0..<totalFiles).compactMap { results[$0] })

        symCount = results.values.reduce(0) { $0 + $1.symbols.count }
        failCount = results.values.filter { $0.astFailed }.count

        // Build scanned paths set for pruneFailedFiles
        let allScannedPaths = Set(fileResults.map { $0.0.path })

        // ── phase 3: parse manifests ──
        let manifests = ManifestParser.parseAll(in: projectPath)
        for manifest in manifests {
            for pkg in manifest.packages {
                try db.insertPackage(pkg)
                pkgCount += 1
            }
        }

        // ── rebuild FTS index ──
        try db.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO symbols_fts(symbols_fts) VALUES('rebuild')")
        }

        // Clear failed_files entries for files that no longer exist in the project
        try db.pruneFailedFiles(knownPaths: allScannedPaths)

        return ScanSummary(
            files: fileCount,
            symbols: symCount,
            packages: pkgCount,
            failed: failCount
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
            return "Cannot enumerate directory: \(path)"
        }
    }
}
