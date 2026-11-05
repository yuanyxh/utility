import CryptoKit
import Foundation

struct EditorDraft: Codable, Equatable {
    let url: String
    let text: String
    let encodingRaw: UInt
    let lineEnding: FileLineEnding
    let fingerprint: FileFingerprint
    let savedAt: Date

    var fileURL: URL { URL(fileURLWithPath: url) }
    var encoding: String.Encoding { String.Encoding(rawValue: encodingRaw) }

    init(
        url: URL, text: String, encoding: String.Encoding, lineEnding: FileLineEnding,
        fingerprint: FileFingerprint, savedAt: Date = Date(),
    ) {
        self.url = url.standardizedFileURL.path
        self.text = text
        self.encodingRaw = encoding.rawValue
        self.lineEnding = lineEnding
        self.fingerprint = fingerprint
        self.savedAt = savedAt
    }
}

/// Crash-safe editor snapshots: one JSON per file under ~/.cache/utility/editor-drafts.
final class EditorDraftStore: @unchecked Sendable {
    static let defaultDirectory = AppPaths.cacheDir.appendingPathComponent("editor-drafts")
    static let maxCount = 20
    static let maxBytes = 50 * 1024 * 1024

    let directory: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL = EditorDraftStore.defaultDirectory) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func fileURL(for url: URL) -> URL {
        let canonical = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key).json")
    }

    func save(_ draft: EditorDraft) throws {
        let data = try encoder.encode(draft)
        let target = fileURL(for: draft.fileURL)
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
        evict()
    }

    func loadAll() -> [EditorDraft] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var drafts: [EditorDraft] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }
            if let draft = try? decoder.decode(EditorDraft.self, from: data) {
                drafts.append(draft)
            } else {
                quarantine(file)
            }
        }
        return drafts.sorted { $0.savedAt > $1.savedAt }
    }

    func delete(for url: URL) {
        try? fm.removeItem(at: fileURL(for: url))
    }

    func delete(_ draft: EditorDraft) {
        try? fm.removeItem(at: fileURL(for: draft.fileURL))
    }

    func evict(maxCount: Int = EditorDraftStore.maxCount, maxBytes: Int = EditorDraftStore.maxBytes) {
        var bytes = 0
        for (index, draft) in loadAll().enumerated() {
            let file = fileURL(for: draft.fileURL)
            let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
            let fileBytes = size?.intValue ?? 0
            if index >= maxCount || bytes + fileBytes > maxBytes {
                try? fm.removeItem(at: file)
            } else {
                bytes += fileBytes
            }
        }
    }

    private func quarantine(_ file: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = file.deletingPathExtension().lastPathComponent
        let target = directory.appendingPathComponent("\(name).corrupt-\(stamp).json")
        try? fm.moveItem(at: file, to: target)
    }
}
