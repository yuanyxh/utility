import Foundation
import GRDB

/// 剪切板条目模型（GRDB Record）
public struct ClipboardItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    /// UUID 字符串作为主键
    public var id: String
    public var timestamp: Date
    /// text / file / image
    public var type: String
    /// 存储的内容数据
    public var content: Data
    /// 来源应用名称
    public var application: String?
    /// 文本内容的纯文本副本（用于去重）
    public var plainText: String?

    public static let databaseTableName = "clipboard_item"

    enum CodingKeys: String, CodingKey {
        case id, timestamp, type, content, application
        case plainText = "search_text"
    }

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        type: String,
        content: Data,
        application: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.content = content
        self.application = application
        if type == "text", let str = String(data: content, encoding: .utf8) {
            plainText = str
        }
    }
}
