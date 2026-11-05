import Foundation

final class FileNode {
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
    var isLoading = false
    var truncated = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
    }
}

struct FileChildren {
    let nodes: [FileNode]
    let truncated: Bool
}

/// Directory enumeration for the file tree. Symlinks are never followed.
enum FileTreeScanner {
    static let directoryLimit = 2000

    static func children(
        of directory: URL, showHidden: Bool, extraIgnores: Set<String>,
        limit: Int = directoryLimit,
    ) -> FileChildren {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [],
            )
        else {
            return FileChildren(nodes: [], truncated: false)
        }

        var nodes: [FileNode] = []
        for url in entries {
            let name = url.lastPathComponent
            if PathRules.isAlwaysHiddenFile(name: name) { continue }
            if !showHidden, name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory == true
            if isDirectory,
                PathRules.shouldSkip(name: name) || extraIgnores.contains(name)
            {
                continue
            }
            nodes.append(FileNode(url: url, isDirectory: isDirectory))
            if nodes.count >= limit {
                return FileChildren(nodes: sorted(nodes), truncated: true)
            }
        }
        return FileChildren(nodes: sorted(nodes), truncated: false)
    }

    static func countFiles(
        at root: URL, showHidden: Bool, extraIgnores: Set<String>,
    ) -> Int {
        var total = 0
        var pending: [URL] = [root]
        while let directory = pending.popLast() {
            let result = children(
                of: directory, showHidden: showHidden, extraIgnores: extraIgnores,
                limit: Int.max,
            )
            for node in result.nodes {
                if node.isDirectory {
                    pending.append(node.url)
                } else {
                    total += 1
                }
            }
        }
        return total
    }

    private static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

@MainActor
final class FileTreeModel {
    let root: URL
    let showHidden: Bool
    let extraIgnores: Set<String>

    private let queue = DispatchQueue(
        label: "com.utility.workspace.filetree", qos: .userInitiated,
    )

    init(root: URL, showHidden: Bool, extraIgnores: [String]) {
        self.root = root
        self.showHidden = showHidden
        self.extraIgnores = Set(extraIgnores)
    }

    func loadRoot(completion: @escaping ([FileNode], Bool) -> Void) {
        let root = root
        let showHidden = showHidden
        let extraIgnores = extraIgnores
        queue.async {
            let result = FileTreeScanner.children(
                of: root, showHidden: showHidden, extraIgnores: extraIgnores,
            )
            DispatchQueue.main.async { completion(result.nodes, result.truncated) }
        }
    }

    func loadChildren(of node: FileNode, completion: @escaping ([FileNode], Bool) -> Void) {
        node.isLoading = true
        let showHidden = showHidden
        let extraIgnores = extraIgnores
        queue.async {
            let result = FileTreeScanner.children(
                of: node.url, showHidden: showHidden, extraIgnores: extraIgnores,
            )
            DispatchQueue.main.async { completion(result.nodes, result.truncated) }
        }
    }
}
