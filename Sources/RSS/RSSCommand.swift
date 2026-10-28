import ArgumentParser
import Foundation

/// RSS command-line interface
/// Usage: utility rss --fetch / --unread / --mark-read <id> / --digest
struct RSSCommand: ParsableCommand {
    /// Run one async action to completion: print the result, exit 0; on error exit 1.
    private func runAsync(_ work: @escaping () async throws -> String) {
        Task {
            do {
                let output = try await work()
                print(output)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                Darwin.exit(1)
            }
        }
        RunLoop.main.run()
    }

    static let configuration = CommandConfiguration(
        commandName: "rss",
        abstract: L10n.RSS.helpHeader,
    )

    @Flag(name: .shortAndLong, help: ArgumentHelp(L10n.RSS.helpFetch))
    var fetch = false

    @Flag(name: .shortAndLong, help: ArgumentHelp(L10n.RSS.helpList))
    var unread = false

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.RSS.helpMarkRead))
    var markRead: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.RSS.helpMarkAllRead))
    var markAllRead = false

    @Flag(name: .long, help: ArgumentHelp(L10n.RSS.helpDigest))
    var digest = false

    @Flag(name: .long, help: ArgumentHelp(L10n.RSS.helpDryRun))
    var dryRun = false

    @Option(name: .long, help: ArgumentHelp(L10n.RSS.helpDate))
    var date: String?

    mutating func run() throws {
        if digest || dryRun {
            let fetchFeeds = fetch
            let previewOnly = dryRun
            let digestDay = date
            runAsync {
                try await RSSDigestService.shared.run(
                    fetch: fetchFeeds,
                    dryRun: previewOnly,
                    day: digestDay,
                )
            }
        }

        if fetch {
            runAsync {
                let new = try await RSSManager.shared.fetchAll()
                return L10n.RSS.fetchDone(count: new.count)
            }
        }

        if unread {
            let items = try RSSManager.shared.unread()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            print(String(data: data, encoding: .utf8)!)
        }

        if let id = markRead {
            try RSSManager.shared.markAsRead(id)
            print(L10n.RSS.markReadDone(id: id))
        }

        if markAllRead {
            try RSSManager.shared.markAllAsRead()
            print(L10n.RSS.markAllReadDone)
        }
    }
}
