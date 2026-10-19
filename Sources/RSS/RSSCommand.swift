import ArgumentParser
import Foundation

/// RSS command-line interface
/// Usage: utility rss --fetch / --unread / --mark-read <id>
struct RSSCommand: ParsableCommand {
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

    mutating func run() throws {
        if fetch {
            Task {
                do {
                    let new = try await RSSManager.shared.fetchAll()
                    print(L10n.RSS.fetchDone(count: new.count))
                    Darwin.exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    Darwin.exit(1)
                }
            }
            RunLoop.main.run()
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
