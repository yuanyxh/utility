import CoreServices
import Foundation

/// Watches one workspace root and reports changed paths on the main thread after
/// a short debounce, so the file tree rescans only the affected folders.
final class FileTreeWatcher {
    enum GitMetadataChange {
        case working
        case head
    }

    var onChange: (([String]) -> Void)?
    /// Fires for repository metadata outside the workspace root, e.g. when the
    /// workspace is a subdirectory of a repo or a linked worktree.
    var onGitChange: ((Bool) -> Void)?

    private var stream: FSEventStreamRef?
    private var gitStreams: [FSEventStreamRef] = []
    private var watchedRoot: String?
    private var watchedGitDirs: [String] = []
    private var showHidden = true
    private let queue = DispatchQueue(
        label: "com.utility.workspace.filetree.watcher", qos: .utility,
    )
    private let lock = NSLock()
    private var pending = Set<String>()
    private var pendingGit = false
    private var pendingGitHead = false
    private var flushScheduled = false
    private let debounce: TimeInterval = 0.4
    private static let trace = ProcessInfo.processInfo.environment["UTILITY_WATCH_TRACE"] == "1"

    /// FSEvents reports canonical paths (`/private/tmp`), which `resolvingSymlinksInPath`
    /// leaves unresolved; `realpath` keeps both sides comparable without a stat per event.
    static func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            return url.resolvingSymlinksInPath().path
        }
        return String(cString: buffer)
    }

    func start(root: URL, showHidden: Bool, gitDirectories: [URL] = []) {
        let path = Self.canonicalPath(root)
        let dirs = gitDirectories.map(Self.canonicalPath)
        guard
            watchedRoot != path || self.showHidden != showHidden || watchedGitDirs != dirs
        else { return }
        stop()
        watchedRoot = path
        self.showHidden = showHidden
        watchedGitDirs = dirs

        stream = makeStream(path: path)
        gitStreams = dirs.filter { $0 != path && !$0.hasPrefix(path + "/") }.compactMap {
            makeStream(path: $0)
        }
    }

    private func makeStream(path: String) -> FSEventStreamRef? {
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
        else { return nil }
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
        return ref
    }

    deinit {
        stop()
    }

    func stop() {
        if let ref = stream {
            stream = nil
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
        }
        for ref in gitStreams {
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
        }
        gitStreams = []
        watchedRoot = nil
        watchedGitDirs = []
    }

    private func receive(paths: [String]) {
        lock.lock()
        let wasEmpty = pending.isEmpty && !pendingGit
        for path in paths {
            if let root = watchedRoot, path.hasPrefix(root + "/") {
                pending.insert(path)
            } else if let change = gitMetadata(for: path) {
                pendingGit = true
                if case .head = change { pendingGitHead = true }
            }
        }
        let shouldSchedule = wasEmpty && !flushScheduled && (pendingGit || !pending.isEmpty)
        if shouldSchedule { flushScheduled = true }
        let treeCount = pending.count
        let gitPending = pendingGit
        lock.unlock()
        if Self.trace {
            debugLog(
                "[Watch] receive \(paths.count) tree=\(treeCount) git=\(gitPending)"
                    + " first=\(paths.first ?? "-")",
            )
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let paths = pending
        let gitChanged = pendingGit
        let gitHead = pendingGitHead
        pending.removeAll()
        pendingGit = false
        pendingGitHead = false
        flushScheduled = false
        lock.unlock()
        let relevant = Array(paths.filter(isRelevant))
        if Self.trace {
            debugLog(
                "[Watch] flush raw=\(paths.count) relevant=\(relevant.count) git=\(gitChanged)"
                    + " head=\(gitHead) root=\(watchedRoot ?? "-") gitDirs=\(watchedGitDirs)",
            )
        }
        guard !relevant.isEmpty || gitChanged else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !relevant.isEmpty { self.onChange?(relevant) }
            if gitChanged { self.onGitChange?(gitHead) }
        }
    }

    /// Paths arrive already resolved because the stream watches the resolved root.
    private func isRelevant(_ path: String) -> Bool {
        guard let root = watchedRoot, path.hasPrefix(root + "/") else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        guard !relative.isEmpty else { return false }
        // Ignore files affect the tree's grey styling even when they are hidden.
        if relative == ".gitignore" || relative == ".git/info/exclude" { return true }
        // Repository metadata never shows in the tree but changes the git status.
        if Self.gitMetadataChange(relative) != nil { return true }
        if PathRules.isAlwaysHiddenFile(name: (path as NSString).lastPathComponent) {
            return false
        }
        if !showHidden,
            relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
        {
            return false
        }
        return !PathRules.containsSkippedDir(relative)
    }

    private func gitMetadata(for path: String) -> GitMetadataChange? {
        for dir in watchedGitDirs where path.hasPrefix(dir + "/") {
            let relative = String(path.dropFirst(dir.count + 1))
            return Self.gitDirectoryChange(relative)
        }
        return nil
    }

    /// Path relative to the workspace root, where `.git` is a path component.
    static func gitMetadataChange(_ relative: String) -> GitMetadataChange? {
        guard let inner = innerGitPath(relative) else { return nil }
        return gitDirectoryChange(inner)
    }

    /// Path relative to the git directory itself, e.g. `index` or `refs/heads/main`.
    static func gitDirectoryChange(_ relative: String) -> GitMetadataChange? {
        switch relative {
        case "HEAD", "packed-refs", "refs": return .head
        case "index", "MERGE_HEAD", "ORIG_HEAD": return .working
        default: return relative.hasPrefix("refs/") ? .head : nil
        }
    }

    private static func innerGitPath(_ relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: ".git"), index + 1 < parts.count else {
            return nil
        }
        return parts[(index + 1)...].joined(separator: "/")
    }
}
