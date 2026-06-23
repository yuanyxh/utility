import Foundation

/// RSS/Atom XML 解析器
public final class RSSParser: NSObject, XMLParserDelegate {
  private var items: [RSSItem] = []
  private var feedName = ""
  private var currentElement = ""
  private var currentTitle = ""
  private var currentLink = ""
  private var currentDesc = ""
  private var currentPubDate = ""
  private var currentGUID = ""
  private var isItem = false

  public func parse(data: Data, feedName: String) -> [RSSItem] {
    self.feedName = feedName
    items = []
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()
    return items
  }

  // MARK: - XMLParserDelegate

  public func parser(
    _: XMLParser, didStartElement elementName: String,
    namespaceURI _: String?, qualifiedName _: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName

    if elementName == "item" || elementName == "entry" {
      isItem = true
      currentTitle = ""
      currentLink = ""
      currentDesc = ""
      currentPubDate = ""
      currentGUID = ""
    }

    // Atom: <link href="..." /> 从属性中取
    if isItem, elementName == "link", let href = attributeDict["href"],
      !href.isEmpty, currentLink.isEmpty
    {
      currentLink = href
    }
  }

  public func parser(_: XMLParser, foundCharacters string: String) {
    guard isItem else { return }
    switch currentElement {
    case "title": currentTitle += string
    case "link":
      // Atom 可能把 link 放属性里
      currentLink += string
    case "description", "summary", "content": currentDesc += string
    case "pubDate", "published", "updated":
      // 多个日期元素时只取第一个（Atom 有 published + updated）
      if currentPubDate.isEmpty { currentPubDate = string }
    case "guid", "id": currentGUID += string
    default: break
    }
  }

  public func parser(
    _: XMLParser, didEndElement elementName: String,
    namespaceURI _: String?, qualifiedName _: String?
  ) {
    guard isItem, elementName == "item" || elementName == "entry" else { return }

    let date = parseDate(currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines))
    let guid = currentGUID.isEmpty ? currentLink : currentGUID

    items.append(
      RSSItem(
        id: guid.trimmingCharacters(in: .whitespacesAndNewlines),
        title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
        link: currentLink.trimmingCharacters(in: .whitespacesAndNewlines),
        itemDescription: currentDesc.trimmingCharacters(in: .whitespacesAndNewlines),
        pubDate: date,
        feedName: feedName
      ))
    isItem = false
  }

  // MARK: - Date Parsing

  private func parseDate(_ str: String) -> Date {
    let posix = Locale(identifier: "en_US_POSIX")
    let formatters: [DateFormatter] = [
      {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
      }(),
      {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
      }(),
      {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
      }(),
      {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
      }(),
      // Atom: "2026-06-17T00:58:31Z" (Z literal = UTC)
      {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssX"
        return f
      }(),
      {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSX"
        return f
      }(),
    ]
    for f in formatters {
      if let date = f.date(from: str) { return date }
    }
    return Date(timeIntervalSince1970: 0)
  }
}
