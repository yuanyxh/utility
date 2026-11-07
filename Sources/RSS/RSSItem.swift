import Foundation
import GRDB

/// RSS item model (GRDB Record)
public struct RSSItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String // guid
    public var title: String
    public var link: String
    public var itemDescription: String
    public var pubDate: Date
    /// False when the feed date is unparseable; `pubDate` holds the sentinel.
    public var dateKnown: Bool
    public var feedName: String
    public var isRead: Bool

    public static let databaseTableName = "rss_item"

    /// Sentinel stored when a feed item has no parsable publication date.
    public static let unknownDate = Date(timeIntervalSince1970: 0)

    enum CodingKeys: String, CodingKey {
        case id, title, link
        case itemDescription = "item_description"
        case pubDate = "pub_date"
        case dateKnown = "date_known"
        case feedName = "feed_name"
        case isRead = "is_read"
    }

    public init(
        id: String, title: String, link: String,
        itemDescription: String, pubDate: Date, dateKnown: Bool = true,
        feedName: String, isRead: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.link = link
        self.itemDescription = itemDescription
        self.pubDate = pubDate
        self.dateKnown = dateKnown
        self.feedName = feedName
        self.isRead = isRead
    }
}
