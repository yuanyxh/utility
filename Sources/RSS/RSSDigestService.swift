import Foundation

/// RSS daily digest pipeline: fetch -> filter -> decide -> expand -> read -> summarize -> render.
final class RSSDigestService {
    static let shared = RSSDigestService()

    private let client = MCPClient.shared

    private init() {}

    private struct Entry {
        var title: String
        var link: String
        var feed: String
        var kind: String = "article"
        var text: String = ""
    }

    private struct SummaryPayload {
        var titleTranslation: String
        var summary: String
    }

    func run(fetch: Bool = true, dryRun: Bool = false, day: String? = nil) async throws -> String {
        L10n.setup()
        let cfg = ConfigManager.shared.config.rss.daily
        let today = day ?? Self.dayString(Date())
        let root = try outputRoot(cfg)
        let archive = RSSDigestRender.archivePath(root: root, day: today)

        if fetch, !dryRun {
            let added = try await RSSManager.shared.fetchAll()
            debugLog("[RSS] fetched \(added.count) new items")
        }

        let items = try RSSManager.shared.unread(maxAgeDays: cfg.maxAgeDays)
        let history = RSSDigestRender.collectHistoryURLs(root: root, exclude: archive)

        var filtered: [RSSDigestRender.Filtered] = []
        let (candidates, seen) = prefilter(items, history: history, filtered: &filtered)
        debugLog("[RSS] unread=\(items.count) candidates=\(candidates.count) prefiltered=\(filtered.count)")

        let (selected, llmResponded) = await select(candidates, cfg: cfg, filtered: &filtered)

        // A dead LLM must not archive an empty digest and mark everything read.
        guard llmResponded || dryRun || candidates.isEmpty else {
            throw NSError(
                domain: "RSSDigest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "LLM unavailable; digest aborted"]
            )
        }

        if dryRun {
            let digests = selected.filter { $0.kind == "digest" }.count
            return "dry-run: unread=\(items.count) candidates=\(candidates.count) "
                + "keep=\(selected.count) digest=\(digests) filtered=\(filtered.count)"
        }

        let switcher = makeSwitcher(cfg.clash)
        switcher?.recover()
        switcher?.apply()
        defer { switcher?.restore() }

        let expanded = await expandDigests(
            selected,
            history: history,
            seen: seen,
            filtered: &filtered,
            cfg: cfg
        )
        let articles = await prepareArticles(expanded, cfg: cfg, filtered: &filtered)

        let merged = mergeWithExisting(articles, filtered: filtered, archive: archive)
        let text = RSSDigestRender.render(day: today, articles: merged.articles, filtered: merged.filtered)
        try write(text, to: archive)
        if cfg.markRead {
            for item in items {
                try? RSSManager.shared.markAsRead(item.id)
            }
        }
        let summary = "rss daily: \(archive.path) articles=\(merged.articles.count) "
            + "filtered=\(merged.filtered.count)"
        debugLog("[RSS] \(summary)")
        let reasonCounts = Dictionary(grouping: merged.filtered, by: \.reason)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        debugLog("[RSS] filter reasons: \(reasonCounts)")
        return summary
    }

    /// Drop link-less, already-archived, and repeated entries before any LLM call.
    private func prefilter(
        _ items: [RSSItem],
        history: Set<String>,
        filtered: inout [RSSDigestRender.Filtered]
    ) -> (candidates: [RSSItem], seen: Set<String>) {
        var candidates: [RSSItem] = []
        var seen: Set<String> = []
        for item in items {
            let link = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else {
                filtered.append(filteredEntry(item, L10n.RSS.filterNoLink))
                continue
            }
            let key = RSSDigestRender.normalizeURL(link)
            if history.contains(key) {
                filtered.append(filteredEntry(item, L10n.RSS.filterHistorical))
                continue
            }
            if seen.contains(key) {
                filtered.append(filteredEntry(item, L10n.RSS.filterDuplicate))
                continue
            }
            seen.insert(key)
            candidates.append(item)
        }
        return (candidates, seen)
    }

    /// Apply the LLM keep/drop decisions; a failed batch keeps everything.
    private func select(
        _ candidates: [RSSItem],
        cfg: RSSDailyConfig,
        filtered: inout [RSSDigestRender.Filtered]
    ) async -> (entries: [Entry], llmResponded: Bool) {
        let (decisions, responded) = await decide(candidates, cfg: cfg)
        var selected: [Entry] = []
        for (index, item) in candidates.enumerated() {
            let decision = decisions[index] ?? (keep: true, kind: "article", reason: "", code: "")
            guard decision.keep else {
                filtered.append(filteredEntry(
                    item,
                    reasonText(code: decision.code, fallback: decision.reason)
                ))
                continue
            }
            selected.append(Entry(
                title: item.title,
                link: item.link,
                feed: item.feedName,
                kind: decision.kind
            ))
        }
        return (selected, responded)
    }

    /// Fetch bodies, summarize them, and keep only entries with a usable summary.
    private func prepareArticles(
        _ entries: [Entry],
        cfg: RSSDailyConfig,
        filtered: inout [RSSDigestRender.Filtered]
    ) async -> [RSSDigestRender.Article] {
        let bodies = await fetchPages(
            entries.map(\.link),
            maxChars: cfg.articleMaxChars,
            timeout: TimeInterval(cfg.fetchTimeout),
            width: cfg.maxConcurrency
        )
        var ready: [Entry] = []
        for var entry in entries {
            guard let text = bodies[entry.link], text.count >= 50 else {
                filtered.append(filteredEntry(entry, L10n.RSS.filterFetchFailed))
                continue
            }
            entry.text = text
            ready.append(entry)
        }

        let summaries = await summarize(ready, cfg: cfg)
        var articles: [RSSDigestRender.Article] = []
        for entry in ready {
            guard let payload = summaries[entry.link],
                  !payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                filtered.append(filteredEntry(entry, L10n.RSS.filterSummaryFailed))
                continue
            }
            articles.append(
                RSSDigestRender.Article(
                    title: entry.title,
                    url: entry.link,
                    titleTranslation: payload.titleTranslation,
                    summary: payload.summary
                )
            )
        }
        return articles
    }

    // MARK: - LLM steps

    private func decide(
        _ items: [RSSItem],
        cfg: RSSDailyConfig
    ) async -> (decisions: [Int: (keep: Bool, kind: String, reason: String, code: String)], responded: Bool) {
        var decisions: [Int: (keep: Bool, kind: String, reason: String, code: String)] = [:]
        var responded = false
        let batch = max(1, cfg.filterBatch)
        var start = 0
        while start < items.count {
            let chunk = Array(items[start ..< min(start + batch, items.count)])
            let lines = chunk.enumerated().map { index, item in
                let description = Self.plainText(item.itemDescription, limit: 300)
                return "[\(index)] \(item.title) | \(item.feedName) | \(description)"
            }
            let tokens = min(4000, max(800, chunk.count * 120))
            let parsed = await chatJSON(
                "rss_filter",
                ["items_text": lines.joined(separator: "\n")],
                label: "rss_filter",
                maxTokens: tokens,
                cfg: cfg
            )
            if let entries = parsed?["items"] as? [[String: Any]] {
                responded = true
                for entry in entries {
                    guard let index = Self.intValue(entry["index"]), index >= 0, index < chunk.count else {
                        continue
                    }
                    var kind = (entry["kind"] as? String) ?? "article"
                    if !["article", "digest", "skip"].contains(kind) { kind = "article" }
                    let keep = Self.boolValue(entry["keep"], default: kind != "skip")
                    decisions[start + index] = (
                        keep: keep,
                        kind: kind == "digest" ? "digest" : "article",
                        reason: ((entry["reason"] as? String) ?? "").trimmingCharacters(in: .whitespaces),
                        code: ((entry["reason_code"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                    )
                }
            } else {
                debugLog("[RSS] filter batch \(start) failed, keep all")
            }
            start += batch
        }
        return (decisions, responded)
    }

    private func summarize(_ entries: [Entry], cfg: RSSDailyConfig) async -> [String: SummaryPayload] {
        var results: [String: SummaryPayload] = [:]
        let batch = max(1, cfg.summaryBatch)
        var start = 0
        while start < entries.count {
            let chunk = Array(entries[start ..< min(start + batch, entries.count)])
            results.merge(await summarizeChunk(chunk, cfg: cfg)) { _, new in new }
            start += batch
        }
        return results
    }

    /// Summarize one batch; a failed batch is split in half so one bad entry cannot drop the rest.
    private func summarizeChunk(_ chunk: [Entry], cfg: RSSDailyConfig) async -> [String: SummaryPayload] {
        guard !chunk.isEmpty else { return [:] }
        let blocks = chunk.enumerated().map { index, entry in
            "[\(index)] 标题：\(entry.title)\n"
                + "来源：\(entry.feed)\n"
                + "正文：\n\(String(entry.text.prefix(6000)))"
        }
        let tokens = min(4000, max(1200, chunk.count * 700))
        let parsed = await chatJSON(
            "rss_summary",
            ["items_text": blocks.joined(separator: "\n\n")],
            label: "rss_summary",
            maxTokens: tokens,
            cfg: cfg
        )
        var results: [String: SummaryPayload] = [:]
        for item in parsed?["items"] as? [[String: Any]] ?? [] {
            guard let index = Self.intValue(item["index"]), index >= 0, index < chunk.count else {
                continue
            }
            results[chunk[index].link] = SummaryPayload(
                titleTranslation: ((item["title_translation"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespaces),
                summary: ((item["summary"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        guard results.isEmpty else { return results }
        guard chunk.count > 1 else {
            debugLog("[RSS] summary failed for \(chunk[0].link)")
            return [:]
        }
        let mid = chunk.count / 2
        var split = await summarizeChunk(Array(chunk[..<mid]), cfg: cfg)
        split.merge(await summarizeChunk(Array(chunk[mid...]), cfg: cfg)) { _, new in new }
        return split
    }

    private func chatJSON(
        _ feature: String,
        _ variables: [String: String],
        label: String,
        maxTokens: Int,
        cfg: RSSDailyConfig
    ) async -> [String: Any]? {
        guard let prompt = RSSPrompt.render(feature, variables) else {
            debugLog("[RSS] prompt missing: \(feature)")
            return nil
        }
        for attempt in 0 ..< 2 {
            do {
                let raw = try await client.chat(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    timeout: TimeInterval(cfg.llmTimeout),
                    disableThinking: true,
                    extraBody: ["thinking": ["type": "disabled"]],
                    label: label
                )
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    debugLog("[RSS] \(label) empty response try \(attempt + 1)")
                    continue
                }
                if let parsed = Self.jsonObject(text) { return parsed }
                debugLog("[RSS] \(label) parse failed try \(attempt + 1), tail=\(text.suffix(160))")
            } catch {
                debugLog("[RSS] \(label) call failed try \(attempt + 1): \(error)")
            }
        }
        return nil
    }

    // MARK: - Digest expansion and fetching

    private func expandDigests(
        _ selected: [Entry],
        history: Set<String>,
        seen: Set<String>,
        filtered: inout [RSSDigestRender.Filtered],
        cfg: RSSDailyConfig
    ) async -> [Entry] {
        var seen = seen
        let digestEntries = selected.filter { $0.kind == "digest" }
        guard !digestEntries.isEmpty else { return selected }

        let pages = await fetchPages(
            digestEntries.map(\.link),
            maxChars: max(cfg.articleMaxChars, 30000),
            timeout: TimeInterval(cfg.fetchTimeout),
            width: cfg.maxConcurrency
        )
        var expanded: [Entry] = []
        for entry in selected {
            guard entry.kind == "digest" else {
                expanded.append(entry)
                continue
            }
            guard let page = pages[entry.link] else {
                filtered.append(filteredEntry(entry, L10n.RSS.filterWeeklyFetchFailed))
                continue
            }
            let links = await digestLinks(
                feed: entry.feed,
                page: page,
                limit: cfg.maxDigestLinks,
                cfg: cfg
            )
            guard !links.isEmpty else {
                filtered.append(filteredEntry(entry, L10n.RSS.filterWeeklyNoLinks))
                continue
            }
            for link in links {
                let key = RSSDigestRender.normalizeURL(link.url)
                if history.contains(key) {
                    filtered.append(RSSDigestRender.Filtered(
                        title: link.title,
                        url: link.url,
                        feed: entry.feed,
                        reason: L10n.RSS.filterHistorical
                    ))
                    continue
                }
                if seen.contains(key) { continue }
                seen.insert(key)
                expanded.append(Entry(title: link.title, link: link.url, feed: entry.feed))
            }
        }
        return expanded
    }

    private func digestLinks(
        feed: String,
        page: String,
        limit: Int,
        cfg: RSSDailyConfig
    ) async -> [(title: String, url: String)] {
        guard let parsed = await chatJSON(
            "rss_digest",
            ["feed_name": feed, "page_text": page],
            label: "rss_digest",
            maxTokens: 2500,
            cfg: cfg
        ), let items = parsed["links"] as? [[String: Any]] else {
            return []
        }
        var links: [(title: String, url: String)] = []
        var seen: Set<String> = []
        for item in items {
            let url = ((item["url"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("http"), !seen.contains(url) else { continue }
            seen.insert(url)
            links.append((title: ((item["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces), url: url))
            if links.count >= max(1, limit) { break }
        }
        return links
    }

    private func fetchPages(
        _ urls: [String],
        maxChars: Int,
        timeout: TimeInterval,
        width: Int
    ) async -> [String: String] {
        let unique = Array(Set(urls.filter { !$0.isEmpty }))
        var results: [String: String] = [:]
        let limit = max(1, width)
        var start = 0
        while start < unique.count {
            let chunk = Array(unique[start ..< min(start + limit, unique.count)])
            await withTaskGroup(of: (String, String?).self) { group in
                for url in chunk {
                    group.addTask { [client] in
                        guard let page = try? await client.readMarkdown(url: url, maxChars: maxChars, timeout: timeout),
                              page.ok,
                              let markdown = page.markdown
                        else { return (url, nil) }
                        return (url, markdown.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                for await (url, text) in group {
                    if let text, !text.isEmpty { results[url] = text }
                }
            }
            start += limit
        }
        return results
    }

    // MARK: - Helpers

    /// A same-day re-run appends new entries instead of replacing the archive.
    private func mergeWithExisting(
        _ articles: [RSSDigestRender.Article],
        filtered: [RSSDigestRender.Filtered],
        archive: URL
    ) -> (articles: [RSSDigestRender.Article], filtered: [RSSDigestRender.Filtered]) {
        guard let existing = try? String(contentsOf: archive, encoding: .utf8) else {
            return (articles, filtered)
        }
        var mergedArticles = RSSDigestRender.parseArticles(existing)
        var seenArticles = Set(mergedArticles.map { RSSDigestRender.normalizeURL($0.url) })
        for article in articles {
            let key = RSSDigestRender.normalizeURL(article.url)
            if seenArticles.contains(key) { continue }
            seenArticles.insert(key)
            mergedArticles.append(article)
        }
        var mergedFiltered = RSSDigestRender.parseFiltered(existing)
        var seenFiltered = Set(mergedFiltered.map(\.dedupeKey))
        for entry in filtered {
            if seenFiltered.contains(entry.dedupeKey) { continue }
            seenFiltered.insert(entry.dedupeKey)
            mergedFiltered.append(entry)
        }
        return (mergedArticles, mergedFiltered)
    }

    private func makeSwitcher(_ clash: RSSClashConfig) -> RSSClashSwitcher? {
        guard clash.enabled else { return nil }
        let group = clash.group.trimmingCharacters(in: .whitespaces)
        let target = clash.target.trimmingCharacters(in: .whitespaces)
        guard !group.isEmpty, !target.isEmpty else {
            debugLog("[RSS] clash enabled but group/target is empty")
            return nil
        }
        return RSSClashSwitcher(
            group: group,
            target: target,
            stateFile: AppPaths.configDir.appendingPathComponent("clash_switch.json")
        )
    }

    /// Map the LLM's enum code to a localized label; free text stays as a fallback.
    private func reasonText(code: String, fallback: String) -> String {
        switch code {
        case "release": return L10n.RSS.filterRelease
        case "ad": return L10n.RSS.filterAd
        case "news": return L10n.RSS.filterNews
        case "personal": return L10n.RSS.filterPersonal
        case "tool": return L10n.RSS.filterTool
        case "duplicate": return L10n.RSS.filterDuplicate
        case "shallow": return L10n.RSS.filterShallow
        case "stale": return L10n.RSS.filterStale
        default: return fallback.isEmpty ? L10n.RSS.filterNoLongTermValue : fallback
        }
    }

    private func filteredEntry(_ item: RSSItem, _ reason: String) -> RSSDigestRender.Filtered {
        RSSDigestRender.Filtered(
            title: item.title,
            url: item.link,
            feed: item.feedName,
            reason: reason
        )
    }

    private func filteredEntry(_ entry: Entry, _ reason: String) -> RSSDigestRender.Filtered {
        RSSDigestRender.Filtered(
            title: entry.title,
            url: entry.link,
            feed: entry.feed,
            reason: reason
        )
    }

    private func outputRoot(_ cfg: RSSDailyConfig) throws -> URL {
        let configured = cfg.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        guard let notes = PythonScriptRunner.resolvedNotesDir() else {
            throw NSError(
                domain: "RSSDigest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "notes directory is not configured"]
            )
        }
        return URL(fileURLWithPath: notes, isDirectory: true).appendingPathComponent("RSS")
    }

    private func write(_ text: String, to archive: URL) throws {
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = archive.appendingPathExtension("tmp")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: archive.path) {
            _ = try FileManager.default.replaceItemAt(archive, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: archive)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func plainText(_ html: String, limit: Int) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&[a-zA-Z#0-9]+;", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func boolValue(_ value: Any?, default fallback: Bool) -> Bool {
        if let bool = value as? Bool { return bool }
        if let text = value as? String {
            return !["false", "0", "no", ""].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
        }
        if let number = value as? NSNumber { return number.boolValue }
        return fallback
    }

    /// Strict parse first; on failure salvage the complete `items` objects that survived truncation.
    private static func jsonObject(_ raw: String?) -> [String: Any]? {
        guard let raw, let start = raw.firstIndex(of: "{") else { return nil }
        let text = String(raw[start...])
        if let object = decodeObject(text) { return object }
        let items = completeItems(text)
        guard !items.isEmpty else { return nil }
        debugLog("[RSS] json salvaged \(items.count) complete items")
        return ["items": items]
    }

    private static func decodeObject(_ text: String) -> [String: Any]? {
        if let object = parseObject(text) { return object }
        let cleaned = escapeControls(text)
        guard cleaned != text else { return nil }
        return parseObject(cleaned)
    }

    private static func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Models often emit raw newlines inside string values; escape them before parsing.
    private static func escapeControls(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var escaping = false
        for ch in text {
            guard inString else {
                if ch == "\"" { inString = true }
                out.append(ch)
                continue
            }
            if escaping {
                escaping = false
                out.append(ch)
            } else if ch == "\\" {
                escaping = true
                out.append(ch)
            } else if ch == "\"" {
                inString = false
                out.append(ch)
            } else if ch == "\n" {
                out.append("\\n")
            } else if ch == "\r" {
                out.append("\\r")
            } else if ch == "\t" {
                out.append("\\t")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Collect every syntactically complete object inside the array that follows `"items"`.
    private static func completeItems(_ text: String) -> [[String: Any]] {
        guard let key = text.range(of: "\"items\""),
              let open = text[key.upperBound...].firstIndex(of: "[")
        else { return [] }
        var objects: [[String: Any]] = []
        var depth = 1
        var inString = false
        var escaping = false
        var start: String.Index?
        var index = text.index(after: open)
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaping { escaping = false } else if ch == "\\" { escaping = true } else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{":
                    if depth == 1 { start = index }
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 1, let from = start, let object = decodeObject(String(text[from ... index])) {
                        objects.append(object)
                    }
                    if depth == 1 { start = nil }
                case "[": depth += 1
                case "]": depth -= 1
                default: break
                }
            }
            index = text.index(after: index)
        }
        return objects
    }
}

/// Loads a bundled feature prompt and fills its `{name}` placeholders once.
enum RSSPrompt {
    static func render(_ feature: String, _ variables: [String: String]) -> String? {
        guard var text = raw(feature) else { return nil }
        for (key, value) in variables {
            text = text.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return text
    }

    private static func raw(_ feature: String) -> String? {
        // SwiftPM flattens resource dirs; the language lives in the file name.
        let candidates = [L10n.currentLanguage, L10n.baselineLanguage]
        for language in candidates {
            guard let url = Bundle.module.url(
                forResource: "\(feature).\(language)",
                withExtension: "md"
            ), let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            return stripFrontMatter(text)
        }
        return nil
    }

    private static func stripFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return text
        }
        return lines[(end + 1)...].joined(separator: "\n")
    }
}
