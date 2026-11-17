import XCTest

@testable import utility

final class RSSParserTests: XCTestCase {
    private func parse(_ xml: String) -> [RSSItem] {
        RSSParser().parse(data: Data(xml.utf8), feedName: "test")
    }

    private func channelXML(_ channelDate: String, itemDate: String = "") -> String {
        let item =
            itemDate.isEmpty
            ? "<item><title>a</title><link>https://e.test/a</link></item>"
            : "<item><title>a</title><link>https://e.test/a</link><pubDate>\(itemDate)</pubDate></item>"
        return """
            <rss version="2.0"><channel>
            <title>t</title><pubDate>\(channelDate)</pubDate>
            \(item)
            </channel></rss>
            """
    }

    func testItemDateWinsOverChannelDate() {
        let items = parse(
            channelXML(
                "Sun, 15 Nov 2026 07:22:55 GMT",
                itemDate: "Tue, 10 Nov 2026 01:02:03 GMT",
            ),
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].dateKnown)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.component(.day, from: items[0].pubDate), 10)
    }

    func testChannelDateFillsMissingItemDate() {
        let items = parse(channelXML("Sun, 15 Nov 2026 07:22:55 GMT"))
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].dateKnown)
        XCTAssertGreaterThan(items[0].pubDate, RSSItem.unknownDate)
    }

    func testUnparseableChannelDateFallsBackToNextElement() {
        let xml = """
            <rss version="2.0"><channel><title>t</title>
            <pubDate> </pubDate>
            <lastBuildDate>Sun, 15 Nov 2026 07:22:55 GMT</lastBuildDate>
            <item><title>a</title><link>https://e.test/a</link></item>
            </channel></rss>
            """
        let items = parse(xml)
        XCTAssertTrue(items[0].dateKnown, "blank pubDate must not lock out lastBuildDate")
    }

    func testPlaceholderChannelDateFallsBackToNextElement() {
        let xml = """
            <rss version="2.0"><channel><title>t</title>
            <pubDate>Mon, 01 Jan 0001 00:00:00 GMT</pubDate>
            <lastBuildDate>Sun, 15 Nov 2026 07:22:55 GMT</lastBuildDate>
            <item><title>a</title><link>https://e.test/a</link></item>
            </channel></rss>
            """
        let items = parse(xml)
        XCTAssertTrue(items[0].dateKnown, "placeholder pubDate must not lock out lastBuildDate")
    }

    func testUnparseableItemDateStillUsesChannelDate() {
        let xml = """
            <rss version="2.0"><channel><title>t</title>
            <pubDate>Sun, 15 Nov 2026 07:22:55 GMT</pubDate>
            <item><title>a</title><link>https://e.test/a</link>
            <pubDate>2026-11-16 17:18:52 +0800</pubDate></item>
            </channel></rss>
            """
        let items = parse(xml)
        XCTAssertTrue(items[0].dateKnown)
    }

    func testNoDateAnywhereStaysUnknown() {
        let xml = """
            <rss version="2.0"><channel><title>t</title>
            <item><title>a</title><link>https://e.test/a</link></item>
            </channel></rss>
            """
        let items = parse(xml)
        XCTAssertFalse(items[0].dateKnown)
        XCTAssertEqual(items[0].pubDate, RSSItem.unknownDate)
    }

    func testAtomUpdatedFeedsChannelDate() {
        let xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
            <title>t</title><updated>2026-11-15T07:22:55Z</updated>
            <entry><title>a</title><id>urn:a</id>
            <link href="https://e.test/a"/></entry>
            </feed>
            """
        let items = parse(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].dateKnown)
    }
}
