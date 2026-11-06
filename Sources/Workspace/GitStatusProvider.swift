import Foundation

/// Single-flight git status shared by the git pane and the file tree.
@MainActor
final class GitStatusProvider {
    static let shared = GitStatusProvider()

    struct Result: Equatable {
        var isRepository = false
        var files: [GitFileStatus] = []
        var ignoredPaths: Set<String> = []
    }

    var onUpdate: ((URL, Result) -> Void)?

    private var cache: [String: Result] = [:]
    private var tasks: [String: Task<Result, Never>] = [:]
    private var generations: [String: Int] = [:]

    func cached(for root: URL) -> Result? {
        cache[key(for: root)]
    }

    func result(for root: URL) async -> Result {
        let key = key(for: root)
        if let cached = cache[key] { return cached }
        if let task = tasks[key] { return await task.value }

        let generation = generations[key, default: 0]
        let service = GitService(root: root)
        let previous = cache[key]
        let task = Task { [weak self] () -> Result in
            var result = Result()
            result.isRepository = await service.isRepository()
            var failed = false
            if result.isRepository {
                do {
                    let status = try await service.status()
                    result.files = status.files
                    result.ignoredPaths = status.ignoredPaths
                } catch {
                    failed = true
                    debugLog("[Git] status failed root=\(root.path) error=\(error)")
                    result.files = previous?.files ?? []
                    result.ignoredPaths = previous?.ignoredPaths ?? []
                }
            }
            guard let self, self.generations[key, default: 0] == generation else { return result }
            if !failed { self.cache[key] = result }
            self.onUpdate?(root, result)
            return result
        }
        tasks[key] = task
        let value = await task.value
        if generations[key, default: 0] == generation { tasks[key] = nil }
        return value
    }

    func invalidate(root: URL) {
        let key = key(for: root)
        cache[key] = nil
        tasks[key] = nil
        generations[key, default: 0] += 1
    }

    private func key(for root: URL) -> String {
        root.standardizedFileURL.path
    }
}
