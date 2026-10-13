import Foundation
import GRDB

/// Clipboard item model (GRDB Record)
public struct ClipboardItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    /// UUID string as primary key
    public var id: String
    public var timestamp: Date
    /// text / file / image
    public var type: String
    /// Stored content data
    public var content: Data
    /// Source application name
    public var application: String?
    /// Plain-text copy of the text content (used for deduplication)
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
        application: String? = nil,
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
