import ArgumentParser
import Foundation

/// RSS 命令行接口
/// 用法: utility rss --fetch / --unread / --mark-read <id>
struct RSSCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rss",
        abstract: "RSS 订阅管理（Headless）"
    )

    @Flag(name: .shortAndLong, help: ArgumentHelp("抓取并更新所有订阅"))
    var fetch = false

    @Flag(name: .shortAndLong, help: ArgumentHelp("列出未读条目（JSON）"))
    var unread = false

    @Option(name: .shortAndLong, help: ArgumentHelp("标记已读（按 ID）"))
    var markRead: String?

    @Flag(name: .long, help: ArgumentHelp("标记全部已读"))
    var markAllRead = false

    mutating func run() throws {
        if fetch {
            Task {
                let new = try await RSSManager.shared.fetchAll()
                print(L10n.RSS.fetchDone(new.count))
                Darwin.exit(0)
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
            print(L10n.RSS.markReadDone(id))
        }

        if markAllRead {
            try RSSManager.shared.markAllAsRead()
            print(L10n.RSS.markAllReadDone)
        }
    }
}
