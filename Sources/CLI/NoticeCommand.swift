import ArgumentParser
import Foundation

/// Registers a reminder; the running app polls the table and posts the notification.
struct NoticeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notice",
        abstract: L10n.CLI.noticeAbstract,
        subcommands: [Add.self, List.self, Cancel.self],
    )
}

// MARK: - add

extension NoticeCommand {
    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: L10n.CLI.noticeAddAbstract)

        @Option(name: .customLong("in"), help: ArgumentHelp(L10n.CLI.noticeInHelp))
        var delay: String?

        @Option(name: .long, help: ArgumentHelp(L10n.CLI.noticeAtHelp))
        var at: String?

        @Argument(help: ArgumentHelp(L10n.CLI.noticeTitleHelp))
        var title: String

        @Argument(help: ArgumentHelp(L10n.CLI.noticeBodyHelp))
        var body: String = ""

        func validate() throws {
            guard (delay == nil) != (at == nil) else {
                throw ValidationError(L10n.CLI.noticeTimeRequired)
            }
        }

        func run() throws {
            let dueAt = try delay.map(NoticeTime.delay) ?? NoticeTime.absolute(at ?? "")
            let record = try NoticeStore.shared.add(
                title: title, body: body.isEmpty ? title : body, dueAt: dueAt,
            )
            print(L10n.CLI.noticeAdded(id: record.id, due: NoticeTime.format(dueAt)))
        }
    }
}

// MARK: - list

extension NoticeCommand {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: L10n.CLI.noticeListAbstract)

        func run() throws {
            let records = try NoticeStore.shared.all()
            guard !records.isEmpty else {
                print(L10n.CLI.noticeEmpty)
                return
            }
            for record in records {
                print("\(record.id) | \(NoticeTime.format(record.dueAt)) | \(record.title)")
            }
        }
    }
}

// MARK: - cancel

extension NoticeCommand {
    struct Cancel: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: L10n.CLI.noticeCancelAbstract)

        @Argument(help: ArgumentHelp(L10n.CLI.noticeIdHelp))
        var id: String

        func run() throws {
            let exists = try NoticeStore.shared.all().contains { $0.id == id }
            guard exists else {
                print(L10n.CLI.noticeNotFound(id: id))
                return
            }
            try NoticeStore.shared.remove([id])
            print(L10n.CLI.noticeCancelled(id: id))
        }
    }
}

// MARK: - time parsing

enum NoticeTime {
    /// Parses `10m`, `30s`, `2h`, `1d`; a bare number means seconds.
    static func delay(_ text: String) throws -> Date {
        let raw = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = raw.last else { throw ValidationError(L10n.CLI.noticeTimeInvalid(value: raw)) }
        let scale: Double
        let number: String
        switch unit {
        case "s": scale = 1; number = String(raw.dropLast())
        case "m": scale = 60; number = String(raw.dropLast())
        case "h": scale = 3600; number = String(raw.dropLast())
        case "d": scale = 86400; number = String(raw.dropLast())
        default: scale = 1; number = raw
        }
        guard let value = Double(number), value > 0 else {
            throw ValidationError(L10n.CLI.noticeTimeInvalid(value: raw))
        }
        return Date().addingTimeInterval(value * scale)
    }

    /// Parses `HH:mm` (today, rolls to tomorrow when past) or `yyyy-MM-dd HH:mm`.
    static func absolute(_ text: String) throws -> Date {
        let raw = text.trimmingCharacters(in: .whitespaces)
        let full = DateFormatter()
        full.locale = Locale(identifier: "en_US_POSIX")
        full.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = full.date(from: raw) { return date }

        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm"
        guard let time = clock.date(from: raw) else {
            throw ValidationError(L10n.CLI.noticeTimeInvalid(value: raw))
        }
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let now = Date()
        guard let today = calendar.date(
            bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now,
        ) else {
            throw ValidationError(L10n.CLI.noticeTimeInvalid(value: raw))
        }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
