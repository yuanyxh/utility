import CoreServices
import Foundation

/// FSEvents-based directory watcher with debounce and incremental symbol update.
///
/// - Monitors the entire project directory recursively
/// - 3-second debounce window to batch rapid changes (save-all, git checkout, etc.)
/// - Only processes files matching ScannerConfig includes
/// - Re-extracts symbols for changed files and updates deps.sqlite
final class FileWatcher {
    private let projectPath: String
    private let scanner: ProjectScanner
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private var debounceItem: DispatchWorkItem?
    private var pendingPaths = NSMutableSet()

    init(projectPath: String) {
        self.projectPath = projectPath
        scanner = ProjectScanner.shared
        queue = DispatchQueue(
            label: "com.utility.filewatcher",
            qos: .utility,
            attributes: .concurrent
        )
    }

    deinit {
        stop()
    }

    // MARK: - Public

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [projectPath]
        let latency: CFTimeInterval = 3.0 // debounce window

        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, pathsPtr, flagsPtr, _ in
                guard let info = info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(pathsPtr).takeUnretainedValue() as! [String]
                var flagArray: [FSEventStreamEventFlags] = []
                for i in 0 ..< numEvents {
                    flagArray.append(flagsPtr[i])
                }
                watcher.onEvent(paths: paths, flags: flagArray)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            debugLog("[Watcher] Failed to create FSEventStream")
            return
        }

        stream = ref
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
        debugLog("[Watcher] Started: \(projectPath)")
    }

    func stop() {
        debounceItem?.cancel()
        debounceItem = nil

        guard let ref = stream else { return }
        stream = nil
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        debugLog("[Watcher] Stopped")
    }

    // MARK: - Events

    private func onEvent(paths: [String], flags: [FSEventStreamEventFlags]) {
        let config = ScannerConfig(projectPath: projectPath)
        var relevant = Set<String>()

        for (i, path) in paths.enumerated() {
            // Skip the project root itself
            guard path != projectPath else { continue }

            let flag = i < flags.count ? flags[i] : 0

            // Determine what changed (FSEventStreamEventFlags constants are Int, cast to UInt32)
            let itemIsFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
            let itemIsDir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
            let itemRemoved = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
            let itemRenamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            let itemModified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            let itemCreated = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)

            let isFile = (flag & itemIsFile) != 0
            let isDir = (flag & itemIsDir) != 0
            let isRemoved = (flag & itemRemoved) != 0
            let isRenamed = (flag & itemRenamed) != 0
            let isModified = (flag & itemModified) != 0 ||
                (flag & itemCreated) != 0 ||
                isRemoved || isRenamed

            guard (isFile || isDir) && isModified else { continue }

            // Compute relative path (standardize to avoid /tmp vs /private/tmp mismatch)
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let relRange = standardizedPath.range(of: projectPath + "/") else { continue }
            let relPath = String(standardizedPath[relRange.upperBound...])

            // Skip excluded paths
            if isDir, config.shouldSkipDirectory(URL(fileURLWithPath: path).lastPathComponent) {
                continue
            }
            if isFile, !config.shouldInclude(relPath) {
                continue
            }
            // Skip .utility dir
            if relPath.hasPrefix(".utility/") || relPath == ".utility" {
                continue
            }

            relevant.insert(relPath)
        }

        guard !relevant.isEmpty else { return }

        // Debounce: cancel previous, schedule new in 3s
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.processChanges(relevant)
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    // MARK: - Incremental update

    private func processChanges(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }

        let projectURL = URL(fileURLWithPath: projectPath)
        let db: ProjectDatabase
        do {
            db = try ProjectDatabase(projectPath: projectPath)
        } catch {
            debugLog("[Watcher] DB init failed: \(error.localizedDescription)")
            return
        }

        var updated = 0
        var failed = 0

        for relPath in paths {
            let fullPath = (projectPath as NSString).appendingPathComponent(relPath)
            let ext = (relPath as NSString).pathExtension.lowercased()
            let parentDir = (relPath as NSString).deletingLastPathComponent

            // File deleted → remove from DB
            if !FileManager.default.fileExists(atPath: fullPath) {
                do {
                    try db.dbQueue.write { db in
                        try db.execute(sql: "DELETE FROM symbols WHERE file_path = ?", arguments: [relPath])
                        try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [relPath])
                        try db.execute(sql: "DELETE FROM failed_files WHERE path = ?", arguments: [relPath])
                    }
                    // Update parent dir file count
                    updateDirFileCount(db: db, dirPath: parentDir)
                    updated += 1
                } catch {
                    debugLog("[Watcher] Delete failed: \(relPath): \(error.localizedDescription)")
                    failed += 1
                }
                continue
            }

            // Read & re-extract
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8),
                  scanner.extractor(for: ext) != nil || ASTExtractorRunner.isSupported(ext)
            else {
                // Not a processable file type, skip
                continue
            }

            let extractor = scanner.extractor(for: ext)
            var symbols: [SymbolRecord] = []
            let prevFails = (try? db.failedFileCount(path: relPath)) ?? 0
            var extractionError: String?

            // Priority 1: AST pipeline (skip after 3 consecutive failures)
            if ASTExtractorRunner.isSupported(ext), prevFails < 3 {
                if let astSymbols = ASTExtractorRunner.extract(from: content, filePath: relPath, ext: ext) {
                    symbols = astSymbols
                } else {
                    extractionError = "AST extraction failed"
                }
            }

            // Priority 2: regex fallback
            if symbols.isEmpty, let extractor = extractor {
                symbols = extractor.extract(from: content, filePath: relPath)
                if !symbols.isEmpty {
                    extractionError = nil // regex found symbols, clear AST failure
                }
            }

            do {
                // Delete old symbols only (keep failed_files to accumulate counter)
                try db.dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM symbols WHERE file_path = ?", arguments: [relPath])
                }

                if !symbols.isEmpty {
                    try db.insertSymbols(symbols)
                }

                // Upsert file record
                let fileRec = FileRecord(
                    path: relPath,
                    dirPath: parentDir,
                    name: (relPath as NSString).lastPathComponent,
                    ext: ext,
                    symCount: symbols.count
                )
                try db.insertFile(fileRec)

                if let err = extractionError {
                    // AST failed → increment counter via ON CONFLICT
                    try db.dbQueue.write { db in
                        try db.execute(sql: """
                          INSERT INTO failed_files (path, fail_count, last_error, last_failed_at)
                          VALUES (?, 1, ?, datetime('now'))
                          ON CONFLICT(path) DO UPDATE SET
                            fail_count = fail_count + 1,
                            last_error = ?,
                            last_failed_at = datetime('now')
                        """, arguments: [relPath, err, err])
                    }
                } else {
                    // AST succeeded (or regex fallback worked) → clear failure counter
                    try db.clearFailedFile(path: relPath)
                }

                // Update parent dir file count
                updateDirFileCount(db: db, dirPath: parentDir)

                updated += 1
            } catch {
                debugLog("[Watcher] Re-extract failed: \(relPath): \(error.localizedDescription)")
                // Record failure
                try? db.dbQueue.write { db in
                    try db.execute(sql: """
                      INSERT INTO failed_files (path, fail_count, last_error, last_failed_at)
                      VALUES (?, 1, ?, datetime('now'))
                      ON CONFLICT(path) DO UPDATE SET
                        fail_count = fail_count + 1,
                        last_error = ?,
                        last_failed_at = datetime('now')
                    """, arguments: [relPath, error.localizedDescription, error.localizedDescription])
                }
                failed += 1
            }
        }

        // Rebuild FTS index after batch update
        do {
            try db.dbQueue.write { db in
                try db.execute(sql: "INSERT INTO symbols_fts(symbols_fts) VALUES('rebuild')")
            }
        } catch {
            debugLog("[Watcher] FTS rebuild failed: \(error.localizedDescription)")
        }

        if updated > 0 || failed > 0 {
            debugLog("[Watcher] Updated: \(updated) file(s), failed: \(failed)")
        }
    }

    /// Recalculate file_count for a directory after file changes.
    private func updateDirFileCount(db: ProjectDatabase, dirPath: String) {
        guard !dirPath.isEmpty else { return }
        do {
            try db.dbQueue.write { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM files WHERE dir_path = ?",
                    arguments: [dirPath]
                ) ?? 0
                try db.execute(
                    sql: "UPDATE directories SET file_count = ? WHERE path = ?",
                    arguments: [count, dirPath]
                )
            }
        } catch {
            debugLog("[Watcher] Dir count update failed: \(dirPath): \(error.localizedDescription)")
        }
    }
}
