import XCTest
@testable import utility

final class RSSDigestRenderTests: XCTestCase {
    private func render(dateKnown: Bool) -> String {
        RSSDigestRender.render(
            day: "2026-11-10",
            articles: [
                RSSDigestRender.Article(
                    title: "Example",
                    url: "https://example.com/a",
                    titleTranslation: "",
                    summary: "summary",
                    dateKnown: dateKnown
                )
            ],
            filtered: []
        )
    }

    func testUnknownDateIsMarkedAndRoundTrips() {
        let known = render(dateKnown: true)
        let unknown = render(dateKnown: false)
        XCTAssertNotEqual(known, unknown)

        let parsed = RSSDigestRender.parseArticles(unknown)
        XCTAssertEqual(parsed.first?.title, "Example")
        XCTAssertEqual(parsed.first?.dateKnown, false)
    }

    func testKnownDateHasNoMark() {
        let parsed = RSSDigestRender.parseArticles(render(dateKnown: true))
        XCTAssertEqual(parsed.first?.title, "Example")
        XCTAssertEqual(parsed.first?.dateKnown, true)
    }
}
