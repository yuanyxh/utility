import CryptoKit
import Foundation

enum FileLineEnding: String, Codable {
    case lf
    case crlf
}

struct FileFingerprint: Equatable, Codable {
    let size: Int64
    let modified: TimeInterval
}

enum ExternalChange: Equatable {
    case unchanged
    case modified
    case deleted
}

enum FileSaveError: Error, Equatable {
    case missing
    case externalModified
    case readOnly
    case writeFailed(String)
}

enum FileLoadResult {
    case text(FileDocument)
    case tooLarge(bytes: Int)
    case binary
    case unsupportedEncoding
    case unreadable(String)
}

final class FileDocument {
    let url: URL
    private(set) var text: String
    private(set) var encoding: String.Encoding
    private(set) var hadBOM: Bool
    private(set) var lineEnding: FileLineEnding
    private(set) var fingerprint: FileFingerprint
    private(set) var loadedContentHash: String
    var isDirty = false

    init(
        url: URL, text: String, encoding: String.Encoding, hadBOM: Bool,
        lineEnding: FileLineEnding, fingerprint: FileFingerprint,
    ) {
        self.url = url
        self.text = text
        self.encoding = encoding
        self.hadBOM = hadBOM
        self.lineEnding = lineEnding
        self.fingerprint = fingerprint
        self.loadedContentHash = FileDocument.contentHash(text)
    }

    // MARK: - Loading

    static func load(url: URL, maxBytes: Int) -> FileLoadResult {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > Int64(maxBytes) { return .tooLarge(bytes: Int(size)) }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        if data.prefix(8192).contains(0) { return .binary }

        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprint = FileFingerprint(size: size, modified: modified)
        guard let decoded = decode(data) else { return .unsupportedEncoding }

        let lineEnding: FileLineEnding = data.contains(Data([0x0D, 0x0A])) ? .crlf : .lf
        return .text(
            FileDocument(
                url: url, text: normalizedText(decoded.text), encoding: decoded.encoding,
                hadBOM: decoded.hadBOM, lineEnding: lineEnding, fingerprint: fingerprint,
            ),
        )
    }

    static func decode(
        _ data: Data,
    ) -> (text: String, encoding: String.Encoding, hadBOM: Bool)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else { return nil }
            return (text, .utf8, true)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
            else { return nil }
            return (text, .utf16LittleEndian, true)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
            else { return nil }
            return (text, .utf16BigEndian, true)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, .utf8, false)
    }

    static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Editing

    func updateText(_ newText: String) {
        text = FileDocument.normalizedText(newText)
    }

    /// Compares size and mtime first, then the decoded content so a restored mtime still counts.
    func checkExternalChange() -> ExternalChange {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return .deleted }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if size != fingerprint.size || abs(modified - fingerprint.modified) > 0.001 {
            return .modified
        }
        guard let data = try? Data(contentsOf: url), let decoded = FileDocument.decode(data)
        else { return .modified }
        let diskHash = FileDocument.contentHash(FileDocument.normalizedText(decoded.text))
        return diskHash == loadedContentHash ? .unchanged : .modified
    }

    func applyReload(_ fresh: FileDocument) {
        text = fresh.text
        encoding = fresh.encoding
        hadBOM = fresh.hadBOM
        lineEnding = fresh.lineEnding
        fingerprint = fresh.fingerprint
        loadedContentHash = fresh.loadedContentHash
        isDirty = false
    }

    func encodedData() -> Data {
        var body = text
        if lineEnding == .crlf {
            body = body.replacingOccurrences(of: "\n", with: "\r\n")
        }
        var data = body.data(using: encoding) ?? Data(body.utf8)
        guard hadBOM else { return data }
        switch encoding {
        case .utf8: data = Data([0xEF, 0xBB, 0xBF]) + data
        case .utf16LittleEndian: data = Data([0xFF, 0xFE]) + data
        case .utf16BigEndian: data = Data([0xFE, 0xFF]) + data
        default: break
        }
        return data
    }

    // MARK: - Saving

    func save(overwriteExternal: Bool) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileSaveError.missing }
        if !overwriteExternal, checkExternalChange() != .unchanged {
            throw FileSaveError.externalModified
        }
        guard fm.isWritableFile(atPath: url.path) else { throw FileSaveError.readOnly }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".utility-save-\(UUID().uuidString).tmp")
        do {
            try encodedData().write(to: temp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw FileSaveError.writeFailed(error.localizedDescription)
        }
        refreshFingerprint()
        loadedContentHash = FileDocument.contentHash(text)
        isDirty = false
    }

    func savedCopy(at newURL: URL) throws -> FileDocument {
        do {
            try encodedData().write(to: newURL, options: .atomic)
        } catch {
            throw FileSaveError.writeFailed(error.localizedDescription)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: newURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? Int64(text.utf8.count)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileDocument(
            url: newURL, text: text, encoding: encoding, hadBOM: hadBOM,
            lineEnding: lineEnding,
            fingerprint: FileFingerprint(size: size, modified: modified),
        )
    }

    private func refreshFingerprint() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(text.utf8.count)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        fingerprint = FileFingerprint(size: size, modified: modified)
    }
}
