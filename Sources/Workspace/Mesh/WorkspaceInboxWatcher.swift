import Foundation

/// Polls inbox directories; files that existed at start are not announced again.
@MainActor
final class WorkspaceInboxWatcher {
    var onMessage: ((String, String) -> Void)?

    private var timer: Timer?
    private var directories: [String: URL] = [:]
    private var seen: [String: Set<String>] = [:]

    func setDirectories(_ updated: [String: URL]) {
        let added = updated.filter { directories[$0.key] != $0.value }
        directories = updated
        for (serviceID, url) in added {
            seen[serviceID] = Set((try? fileNames(in: url)) ?? [])
        }
        seen = seen.filter { updated[$0.key] != nil }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
        if directories.isEmpty { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        directories = [:]
        seen = [:]
    }

    private func fileNames(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".json") }
    }

    func pollNow() {
        poll()
    }

    private func poll() {
        for (serviceID, directory) in directories {
            guard let names = try? fileNames(in: directory) else { continue }
            for name in names where seen[serviceID]?.contains(name) == false {
                seen[serviceID, default: []].insert(name)
                let file = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: file),
                    let text = String(data: data, encoding: .utf8)
                else { continue }
                onMessage?(serviceID, text)
            }
        }
    }
}
