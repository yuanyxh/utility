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
    private let graphScanner: GraphScanner?
    private var stream: FSEventStreamRef?

    /// Serial queue for FSEventStream delivery (FSEventStream requires serial).
    private let eventQueue: DispatchQueue

    /// Thread-safe state for the coalescing stack.
    private let lock = NSLock()
    private var pending = Set<String>()
    private var isScanning = false
    private var timerScheduled = false

    init(projectPath: String, graphScanner: GraphScanner?) {
        self.projectPath = projectPath
        self.graphScanner = graphScanner
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
            // Full scans use .skipsHiddenFiles; apply to dirs too (.git/objects leaked).
            if relPath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            let stateDirs = [".agent-gateway", ".utility"]
            if stateDirs.contains(where: {
                relPath == $0 || relPath.hasPrefix($0 + "/")
            }) {
                continue
            }

            relevant.insert(relPath)
        }

        guard !relevant.isEmpty else { return }

        // Push to stack (dedup) and schedule timer if needed
        lock.lock()
        let wasEmpty = pending.isEmpty
        pending.formUnion(relevant)

        if wasEmpty, !isScanning {
            scheduleTimer()
        }
        lock.unlock()
    }

    // MARK: - Coalescing scan

    /// Called while holding `lock`. Schedules a 3-second scan timer if none is pending.
    private func scheduleTimer() {
        guard !timerScheduled else { return }
        timerScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.executeScan()
        }
    }

    /// Copy pending set, clear, then scan. After scan, check for new items and reschedule.
    private func executeScan() {
        lock.lock()
        timerScheduled = false

        guard !pending.isEmpty else {
            lock.unlock()
            return
        }

        let paths = pending
        pending.removeAll()
        isScanning = true
        lock.unlock()

        processChanges(paths)
        debugLog("[Watcher] Scan done")

        lock.lock()
        isScanning = false
        let hasMore = !pending.isEmpty
        lock.unlock()

        if hasMore {
            lock.lock()
            scheduleTimer()
            lock.unlock()
        }
    }

    // MARK: - Incremental update

    private func processChanges(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }

        let deleted = paths.filter {
            !FileManager.default.fileExists(
                atPath: (projectPath as NSString).appendingPathComponent($0),
            )
        }
        let existing = paths.subtracting(deleted)

        processGraphChanges(deleted: deleted, existing: existing)
        debugLog("[Watcher] Scan result: \(existing.count) updated, \(deleted.count) deleted")
    }

    /// Mirrors file events into the graph engine. Failures are logged, never fatal.
    private func processGraphChanges(deleted: Set<String>, existing: Set<String>) {
        guard let graphScanner else { return }
        for relPath in deleted.sorted() {
            do {
                try graphScanner.removeFile(relPath: relPath)
            } catch {
                debugLog("[Watcher] Graph delete failed: \(relPath): \(error.localizedDescription)")
            }
        }
        for relPath in existing.sorted() {
            do {
                _ = try graphScanner.indexFile(relPath: relPath)
            } catch {
                debugLog("[Watcher] Graph update failed: \(relPath): \(error.localizedDescription)")
            }
        }
    }
}
