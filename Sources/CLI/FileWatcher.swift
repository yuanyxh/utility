import CoreServices
import Foundation

/// FSEvents-based directory watcher with stack-based coalescing.
///
/// - All file changes are deduplicated into a pending set
/// - Timer starts when first item enters an empty set
/// - After 3 seconds: copy set → clear → scan
/// - New changes during scan accumulate in the set
/// - After scan completes, if set is non-empty, start a new timer
final class FileWatcher {
    private let projectPath: String
    private let scanner: ProjectScanner
    private var stream: FSEventStreamRef?

    /// Serial queue for FSEventStream delivery (FSEventStream requires serial).
    private let eventQueue: DispatchQueue

    /// Thread-safe state for the coalescing stack.
    private let lock = NSLock()
    private var pending = Set<String>()
    private var isScanning = false
    private var timerScheduled = false

    init(projectPath: String) {
        self.projectPath = projectPath
        scanner = ProjectScanner.shared
        eventQueue = DispatchQueue(label: "com.utility.filewatcher.events", qos: .utility)
        debugLog("[Watcher] Init: \(projectPath)")
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
            copyDescription: nil,
        )

        let paths = [projectPath]
        let latency: CFTimeInterval = 3.0

        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, pathsPtr, flagsPtr, _ in
                guard let info else { return }
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
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents),
        ) else {
            debugLog("[Watcher] Failed to create FSEventStream")
            return
        }

        stream = ref
        FSEventStreamSetDispatchQueue(ref, eventQueue)
        FSEventStreamStart(ref)
        debugLog("[Watcher] Started: \(projectPath)")
    }

    func stop() {
        guard let ref = stream else { return }
        stream = nil
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        debugLog("[Watcher] Stopped")
    }

    // MARK: - Events

    /// Called on `eventQueue` (serial). FSEventStream requires a serial dispatch queue.
    private func onEvent(paths: [String], flags: [FSEventStreamEventFlags]) {
        debugLog("[Watcher] FSEvent received: \(paths.count) path(s)")

        let config = ScannerConfig(projectPath: projectPath)
        var relevant = Set<String>()

        for (i, path) in paths.enumerated() {
            guard path != projectPath else { continue }

            let flag = i < flags.count ? flags[i] : 0

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
            let isModified = (flag & itemModified) != 0
                || (flag & itemCreated) != 0
                || isRemoved || isRenamed

            guard (isFile || isDir) && isModified else { continue }

            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let relRange = standardizedPath.range(of: projectPath + "/") else { continue }
            let relPath = String(standardizedPath[relRange.upperBound...])

            if isDir, config.shouldSkipDirectory(URL(fileURLWithPath: path).lastPathComponent) {
                continue
            }
            if isFile, !config.shouldInclude(relPath) {
                continue
            }
            if relPath.hasPrefix(".utility/") || relPath == ".utility" {
                continue
            }

            relevant.insert(relPath)
        }

        guard !relevant.isEmpty else {
            debugLog("[Watcher] All \(paths.count) event(s) filtered out")
            return
        }

        debugLog("[Watcher] Relevant: \(relevant.sorted().joined(separator: ", "))")

        // Push to stack (dedup) and schedule timer if needed
        lock.lock()
        let wasEmpty = pending.isEmpty
        pending.formUnion(relevant)
        debugLog("[Watcher] Pending: \(pending.count) file(s), wasEmpty=\(wasEmpty), isScanning=\(isScanning)")

        if wasEmpty, !isScanning {
            scheduleTimer()
        }
        lock.unlock()
    }

    // MARK: - Coalescing scan

    /// Called while holding `lock`. Schedules a 3-second scan timer if none is pending.
    private func scheduleTimer() {
        guard !timerScheduled else {
            debugLog("[Watcher] Timer already scheduled, skip")
            return
        }
        timerScheduled = true
        debugLog("[Watcher] Timer scheduled: scan in 3s")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.executeScan()
        }
    }

    /// Copy pending set, clear, then scan. After scan, check for new items and reschedule.
    private func executeScan() {
        lock.lock()
        timerScheduled = false

        guard !pending.isEmpty else {
            debugLog("[Watcher] Scan skipped: nothing pending")
            lock.unlock()
            return
        }

        let paths = pending
        pending.removeAll()
        isScanning = true
        lock.unlock()

        debugLog("[Watcher] Scan starting: \(paths.count) file(s)")
        processChanges(paths)
        debugLog("[Watcher] Scan done")

        lock.lock()
        isScanning = false
        let hasMore = !pending.isEmpty
        lock.unlock()

        if hasMore {
            debugLog("[Watcher] More items during scan, rescheduling")
            lock.lock()
            scheduleTimer()
            lock.unlock()
        }
    }

    // MARK: - Incremental update

    private func processChanges(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }

        let db: ProjectDatabase
        do {
            db = try ProjectDatabase(projectPath: projectPath)
        } catch {
            debugLog("[Watcher] DB init failed: \(error.localizedDescription)")
            return
        }

        var updated = 0
        var failed = 0

        for relPath in paths.sorted() {
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
                    updateDirFileCount(db: db, dirPath: parentDir)
                    updated += 1
                    debugLog("[Watcher] Deleted: \(relPath)")
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
                debugLog("[Watcher] Unsupported: \(relPath)")
                continue
            }

            let extractor = scanner.extractor(for: ext)
            var symbols: [SymbolRecord] = []
            let prevFails = (try? db.failedFileCount(path: relPath)) ?? 0
            var extractionError: String?
            var extractionSource = ""

            // Priority 1: AST pipeline
            if ASTExtractorRunner.isSupported(ext), prevFails < 3 {
                if let astSymbols = ASTExtractorRunner.extract(from: content, filePath: relPath, ext: ext) {
                    symbols = astSymbols
                    extractionSource = "ast"
                } else {
                    extractionError = "AST extraction failed"
                }
            }

            // Priority 2: regex fallback
            if symbols.isEmpty, let extractor {
                symbols = extractor.extract(from: content, filePath: relPath)
                if !symbols.isEmpty {
                    extractionSource = "regex"
                    extractionError = nil
                }
            }

            do {
                try db.dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM symbols WHERE file_path = ?", arguments: [relPath])
                }

                if !symbols.isEmpty {
                    try db.insertSymbols(symbols)
                }

                let fileRec = FileRecord(
                    path: relPath,
                    dirPath: parentDir,
                    name: (relPath as NSString).lastPathComponent,
                    ext: ext,
                    symCount: symbols.count,
                )
                try db.insertFile(fileRec)

                if let err = extractionError {
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
                    try db.clearFailedFile(path: relPath)
                }

                updateDirFileCount(db: db, dirPath: parentDir)
                updated += 1
                debugLog("[Watcher] Indexed: \(relPath) (\(symbols.count) syms via \(extractionSource))")
            } catch {
                debugLog("[Watcher] Re-extract failed: \(relPath): \(error.localizedDescription)")
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
            debugLog("[Watcher] FTS rebuilt")
        } catch {
            debugLog("[Watcher] FTS rebuild failed: \(error.localizedDescription)")
        }

        debugLog("[Watcher] Scan result: \(updated) indexed, \(failed) failed, \(paths.count) total")
    }

    private func updateDirFileCount(db: ProjectDatabase, dirPath: String) {
        guard !dirPath.isEmpty else { return }
        do {
            try db.dbQueue.write { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM files WHERE dir_path = ?",
                    arguments: [dirPath],
                ) ?? 0
                try db.execute(
                    sql: "UPDATE directories SET file_count = ? WHERE path = ?",
                    arguments: [count, dirPath],
                )
            }
        } catch {
            debugLog("[Watcher] Dir count update failed: \(dirPath): \(error.localizedDescription)")
        }
    }
}
