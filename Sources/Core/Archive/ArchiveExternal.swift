import Foundation

/// Enumerates user-visible directories outside the app config root.
///
/// Symlinks are skipped instead of followed: a link can escape the directory or
/// loop back into it, and neither case should end up in an export.
enum ArchiveExternal {
    static let excludedNames: Set<String> = [".git", ".DS_Store", ".trash"]
    static let excludedSuffixes = [".tmp", ".lock"]

    struct Scan: Sendable, Equatable {
        var files: [URL] = []
        var bytes = 0
        var skippedSymlinks = 0
        var skippedExcluded = 0
    }

    static func scan(root: URL, fileManager: FileManager = .default) -> Scan {
        var result = Scan()
        guard fileManager.fileExists(atPath: root.path) else { return result }

        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true },
            )
        else { return result }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                result.skippedExcluded += 1
                continue
            }
            if values.isSymbolicLink == true {
                result.skippedSymlinks += 1
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if isExcluded(name: url.lastPathComponent) {
                result.skippedExcluded += 1
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            result.files.append(url)
            result.bytes += values.fileSize ?? 0
        }

        result.files.sort {
            relativePath(of: $0, root: root) < relativePath(of: $1, root: root)
        }
        return result
    }

    static func isExcluded(name: String) -> Bool {
        excludedNames.contains(name) || excludedSuffixes.contains { name.hasSuffix($0) }
    }

    static func relativePath(of url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}
