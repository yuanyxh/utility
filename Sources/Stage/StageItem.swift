import Cocoa
import GRDB
import UniformTypeIdentifiers

/// 暂存条目（GRDB Record）
public struct StageItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var timestamp: Date
    /// text / fileURL / fileGroup / html / url
    public var type: String
    /// 文本内容 UTF-8 / 文件 bookmark / fileGroup JSON paths / html / URL UTF-8
    public var content: Data

    public static let databaseTableName = "stage_item"

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                type: String,
                content: Data)
    {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.content = content
    }

    public func resolveFileURL() -> URL? {
        guard type == "fileURL" else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: content,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale)
    }

    public func resolveFileGroup() -> [URL] {
        guard type == "fileGroup" else { return [] }
        guard let paths = try? JSONDecoder().decode([String].self, from: content) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// 显示用摘要
    public var displayText: String {
        switch type {
        case "text":
            let str = String(data: content, encoding: .utf8) ?? ""
            return str.prefix(80) + (str.count > 80 ? "…" : "")
        case "fileURL":
            if let url = resolveFileURL() {
                return url.lastPathComponent
            }
            return L10n.Stage.file
        case "fileGroup":
            let count = resolveFileGroup().count
            return L10n.Stage.fileCount(count)
        case "html":
            let str = String(data: content, encoding: .utf8) ?? ""
            // 取纯文本摘要（去标签）
            let stripped = str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.prefix(60) + (stripped.count > 60 ? "…" : "")
        case "url":
            let str = String(data: content, encoding: .utf8) ?? ""
            return String(str.prefix(60))
        default:
            return L10n.Stage.unknown
        }
    }

    /// 显示用图标（NSImage）
    public var iconImage: NSImage? {
        switch type {
        case "text":
            return nil
        case "fileURL":
            if let url = resolveFileURL() {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSWorkspace.shared.icon(for: .data)
        case "fileGroup":
            return NSWorkspace.shared.icon(for: .folder)
        case "html":
            return NSWorkspace.shared.icon(for: .html)
        case "url":
            return NSWorkspace.shared.icon(for: .url)
        default:
            return nil
        }
    }
}
