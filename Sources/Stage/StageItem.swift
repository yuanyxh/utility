import Foundation
import GRDB

/// 暂存条目（GRDB Record）
public struct StageItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var timestamp: Date
    /// text / fileURL / image / url / fileGroup
    public var type: String
    /// 文本内容 UTF-8 / 文件 bookmark / 图片 Data / URL UTF-8 / fileGroup JSON paths
    public var content: Data

    public static let databaseTableName = "stage_item"

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                type: String,
                content: Data) {
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
            return "文件"
        case "fileGroup":
            let count = resolveFileGroup().count
            return "\(count) 个文件"
        case "image":
            return "图片"
        case "url":
            let str = String(data: content, encoding: .utf8) ?? ""
            return String(str.prefix(60))
        default:
            return "(未知)"
        }
    }

    /// 显示用图标字符
    public var icon: String {
        switch type {
        case "text": return "📄"
        case "fileURL": return "📁"
        case "fileGroup": return "📁"
        case "image": return "🖼"
        case "url": return "🔗"
        default: return "📄"
        }
    }
}
