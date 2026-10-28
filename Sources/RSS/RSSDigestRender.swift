import Foundation

/// Markdown rendering and history dedup for the RSS daily digest.
enum RSSDigestRender {
    struct Article {
        var title: String
        var url: String
        var titleTranslation: String
        var summary: String
    }

    struct Filtered {
        var title: String
        var url: String
        var feed: String
        var reason: String

        /// URL when present, otherwise the title; keeps same-day re-runs idempotent.
        var dedupeKey: String {
            let link = RSSDigestRender.normalizeURL(url)
            return link.isEmpty ? title : link
        }
    }

    /// Dedup key: strip query/fragment and trailing slash.
    static func normalizeURL(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "[?#].*$", options: .regularExpression) {
            value.removeSubrange(range)
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// Every URL already present in archived digests; used to skip repeat coverage.
    static func collectHistoryURLs(root: URL, exclude: URL?) -> Set<String> {
        var urls: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return urls }
        let excluded = exclude?.standardizedFileURL
        for case let path as URL in enumerator where path.pathExtension == "md" {
            if let excluded, path.standardizedFileURL == excluded { continue }
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            urls.formUnion(urlsIn(text).map(normalizeURL))
        }
        urls.remove("")
        return urls
    }

    static func archivePath(root: URL, day: String) -> URL {
        let month = Int(day.dropFirst(5).prefix(2)) ?? 1
        let quarters = [
            L10n.RSS.quarter1, L10n.RSS.quarter2, L10n.RSS.quarter3, L10n.RSS.quarter4,
        ]
        let quarter = quarters[min(max((month - 1) / 3, 0), 3)]
        return root
            .appendingPathComponent(String(day.prefix(4)))
            .appendingPathComponent(quarter)
            .appendingPathComponent("\(day).md")
    }

    static func decorateTitle(_ title: String, translation: String) -> String {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let zh = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zh.isEmpty, zh != base, !containsCJK(base) else { return base }
        return "\(base)(\(zh))"
    }

    /// Re-parse an existing digest so a re-run can merge into it instead of replacing it.
    static func parseArticles(_ text: String) -> [Article] {
        var result: [Article] = []
        var current: Article?
        for line in text.components(separatedBy: "\n") {
            if let parsed = linkParts(line) {
                if let current { result.append(current) }
                current = Article(title: parsed.title, url: parsed.url, titleTranslation: "", summary: "")
            } else if var pending = current, line.hasPrefix("> ") {
                pending.summary = String(line.dropFirst(2))
                current = pending
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// Re-parse the filtered section so a re-run keeps earlier filter reasons.
    static func parseFiltered(_ text: String) -> [Filtered] {
        let header = L10n.RSS.digestFilteredHeader
        let regex = try? NSRegularExpression(
            pattern: #"^- (?:\[(.*?)\]\((\S+?)\)|(.+?)) — \[(.*?)\] ?(.*)$"#
        )
        var inSection = false
        var result: [Filtered] = []
        for line in text.components(separatedBy: "\n") {
            if line == header {
                inSection = true
                continue
            }
            guard inSection else { continue }
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("- "), let regex else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            let title = group(1).isEmpty ? group(3) : group(1)
            result.append(Filtered(
                title: title,
                url: group(2),
                feed: group(4),
                reason: group(5)
            ))
        }
        return result
    }

    static func render(day: String, articles: [Article], filtered: [Filtered]) -> String {
        var lines = [L10n.RSS.digestTitle(day: day), ""]
        if articles.isEmpty {
            lines.append(L10n.RSS.digestEmpty)
            lines.append("")
        }
        for item in articles {
            let title = decorateTitle(item.title, translation: item.titleTranslation)
            lines.append(contentsOf: [
                "---",
                "",
                "## [\(title)](\(item.url))",
                "",
                "> \(summaryLine(item.summary))",
                "",
            ])
        }
        if !articles.isEmpty {
            lines.append(contentsOf: ["---", ""])
        }
        if !filtered.isEmpty {
            lines.append(contentsOf: [L10n.RSS.digestFilteredHeader, ""])
            for item in filtered {
                let title = item.title.isEmpty ? item.url : item.title
                let prefix = item.url.isEmpty ? "- \(title)" : "- [\(title)](\(item.url))"
                lines.append("\(prefix) — [\(item.feed)] \(item.reason)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    // MARK: - Internal

    private static func linkParts(_ line: String) -> (title: String, url: String)? {
        guard line.hasPrefix("## [") else { return nil }
        let body = line.dropFirst(4)
        guard let close = body.range(of: "](", options: .backwards),
              body.hasSuffix(")")
        else { return nil }
        let title = String(body[body.startIndex ..< close.lowerBound])
        let url = String(body[close.upperBound...].dropLast())
        guard !url.isEmpty else { return nil }
        return (title, url)
    }

    /// Keep one article per line: a multi-line summary would be dropped on re-parse.
    private static func summaryLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func urlsIn(_ text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>)\]]+"#)
        let range = NSRange(text.startIndex..., in: text)
        return (regex?.matches(in: text, range: range) ?? []).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00 ... 0x9FA5).contains($0.value) }
    }
}
