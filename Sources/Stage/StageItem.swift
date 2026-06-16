import Foundation
import GRDB

/// 暂存条目（GRDB Record）
public struct StageItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var timestamp: Date
    /// text / fileURL
    public var type: String
    /// 文本内容 UTF-8 / 文件 bookmark data
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
                         options: .withSecurityScope,
                         relativeTo: nil,
                         bookmarkDataIsStale: &isStale)
    }
}
