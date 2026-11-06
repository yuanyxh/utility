import CoreServices
import Foundation

/// Watches one workspace root and reports changed paths on the main thread after
/// a short debounce, so the file tree rescans only the affected folders.
final class FileTreeWatcher {
    var onChange: (([String]) -> Void)?

    private var stream: FSEventStreamRef?
    private var watchedRoot: String?
    private var showHidden = true
    private let queue = DispatchQueue(
        label: "com.utility.workspace.filetree.watcher", qos: .utility,
    )
    private let lock = NSLock()
    private var pending = Set<String>()
    private var flushScheduled = false
    private let debounce: TimeInterval = 0.4

    func start(root: URL, showHidden: Bool) {
        let path = root.resolvingSymlinksInPath().path
        guard watchedRoot != path || self.showHidden != showHidden else { return }
        stop()
        watchedRoot = path
        self.showHidden = showHidden

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil,
        )
        guard
            let ref = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, paths, _, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<FileTreeWatcher>.fromOpaque(info)
                        .takeUnretainedValue()
                    let changed =
                        Unmanaged<CFArray>.fromOpaque(paths)
                        .takeUnretainedValue() as! [String]
                    watcher.receive(paths: changed)
                },
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents,
                ),
            )
        else { return }

        stream = ref
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
    }

    deinit {
        stop()
    }

    func stop() {
        guard let ref = stream else { return }
        stream = nil
        watchedRoot = nil
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
    }

    private func receive(paths: [String]) {
        lock.lock()
        let wasEmpty = pending.isEmpty
        pending.formUnion(paths)
        let shouldSchedule = wasEmpty && !flushScheduled
        if shouldSchedule { flushScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let paths = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !paths.isEmpty else { return }
        let relevant = Array(paths.filter(isRelevant))
        guard !relevant.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(relevant) }
    }

    private func isRelevant(_ path: String) -> Bool {
        guard let root = watchedRoot else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root + "/") else { return false }
        let relative = String(resolved.dropFirst(root.count + 1))
        guard !relative.isEmpty else { return false }
        // Ignore files affect the tree's grey styling even when they are hidden.
        if relative == ".gitignore" || relative == ".git/info/exclude" { return true }
        if PathRules.isAlwaysHiddenFile(name: (resolved as NSString).lastPathComponent) {
            return false
        }
        if !showHidden,
            relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
        {
            return false
        }
        return !PathRules.containsSkippedDir(relative)
    }
}
