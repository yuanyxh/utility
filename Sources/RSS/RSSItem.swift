import Foundation
import GRDB

/// RSS 条目模型（GRDB Record）
public struct RSSItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String       // guid
    public var title: String
    public var link: String
    public var itemDescription: String
    public var pubDate: Date
    public var feedName: String
    public var isRead: Bool

    public static let databaseTableName = "rss_item"

    public init(id: String, title: String, link: String,
                itemDescription: String, pubDate: Date,
                feedName: String, isRead: Bool = false) {
        self.id = id
        self.title = title
        self.link = link
        self.itemDescription = itemDescription
        self.pubDate = pubDate
        self.feedName = feedName
        self.isRead = isRead
    }
}
