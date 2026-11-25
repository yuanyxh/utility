import ArgumentParser
import Foundation
import Yams

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

enum WorkspaceMeshCLI {
    static func gatewayPort(configURL: URL = AppPaths.configFile) -> Int? {
        if let text = try? String(contentsOf: configURL, encoding: .utf8),
            let yaml = (try? Yams.load(yaml: text)) as? [String: Any],
            let mcp = yaml["mcp"] as? [String: Any],
            let port = mcp["port"] as? Int, port > 0
        {
            return port
        }
        return PortProbe.recordedPort(service: "mcp")
    }

    static func client() throws -> MeshClient {
        let override = (ProcessInfo.processInfo.environment["UTILITY_GATEWAY_URL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            guard let url = URL(string: override) else {
                throw ValidationError("invalid UTILITY_GATEWAY_URL: \(override)")
            }
            return MeshClient(baseURL: url)
        }
        guard let port = gatewayPort() else {
            throw ValidationError(L10n.CLI.workspaceNotEnabled)
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw ValidationError("invalid gateway port \(port)")
        }
        return MeshClient(baseURL: url)
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func loadDocument() throws -> WorkspaceDocument {
        guard let document = try WorkspaceStore().load() else {
            throw ValidationError("workspaces.json not found")
        }
        return document
    }

    static func listCards() throws -> [MeshCard] {
        do {
            return try blocking { try await client().list() }
        } catch let error as MeshError where error.code == "http_404" {
            throw ValidationError(L10n.CLI.workspaceNotEnabled)
        }
    }

    static func sendMessage(sender: String, recipient: String, kind: String, text: String) throws -> String {
        do {
            return try blocking {
                try await client().send(sender: sender, recipient: recipient, kind: kind, text: text)
            }
        } catch let error as MeshError where error.code == "http_404" {
            throw ValidationError(L10n.CLI.workspaceNotEnabled)
        }
    }

    /// Bridges the async client into ArgumentParser's synchronous commands.
    static func blocking<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else { throw ValidationError("no result") }
        return try result.get()
    }
}

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: L10n.CLI.workspaceAbstract,
        subcommands: [
            Enable.self, Disable.self, Status.self, List.self, Send.self, Inbox.self,
        ],
    )
}

extension WorkspaceCommand {
    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: L10n.CLI.workspaceEnableHelp)

        @Option(name: .customLong("workspace"))
        var workspace: String

        @Option(name: .customLong("start-command"), help: ArgumentHelp(L10n.CLI.workspaceEnableHelp))
        var startCommand: String?

        func run() throws {
            var document = try WorkspaceMeshCLI.loadDocument()
            guard
                let index = document.workspaces.firstIndex(where: {
                    $0.id == workspace || $0.path == workspace
                })
            else { throw ValidationError("workspace not found: \(workspace)") }
            var config = document.workspaces[index].protocolConfig ?? WorkspaceProtocolConfig()
            config.enabled = true
            if let startCommand { config.startCommand = startCommand }
            document.workspaces[index].protocolConfig = config
            try WorkspaceStore().save(document)
            print("enabled \(document.workspaces[index].id)")
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: L10n.CLI.workspaceDisableHelp)

        @Option(name: .customLong("workspace"))
        var workspace: String

        func run() throws {
            var document = try WorkspaceMeshCLI.loadDocument()
            guard
                let index = document.workspaces.firstIndex(where: {
                    $0.id == workspace || $0.path == workspace
                })
            else { throw ValidationError("workspace not found: \(workspace)") }
            var config = document.workspaces[index].protocolConfig ?? WorkspaceProtocolConfig()
            config.enabled = false
            document.workspaces[index].protocolConfig = config
            try WorkspaceStore().save(document)
            print("disabled \(document.workspaces[index].id)")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: L10n.CLI.workspaceStatusHelp)

        @Flag(name: .customLong("json"), help: ArgumentHelp(L10n.CLI.workspaceJsonHelp))
        var json = false

        func run() throws {
            let showJSON = json
            let cards = try WorkspaceMeshCLI.listCards()
            if showJSON {
                print(try WorkspaceMeshCLI.encode(cards))
                return
            }
            for card in cards {
                print("\(card.id)\t\(card.status)\t\(card.name)")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: L10n.CLI.workspaceListHelp)

        @Flag(name: .customLong("json"), help: ArgumentHelp(L10n.CLI.workspaceJsonHelp))
        var json = false

        func run() throws {
            let showJSON = json
            let cards = try WorkspaceMeshCLI.listCards()
            if showJSON {
                print(try WorkspaceMeshCLI.encode(cards))
                return
            }
            for card in cards {
                print("\(card.id)\t\(card.name)")
            }
        }
    }

    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: L10n.CLI.workspaceSendHelp)

        @Option(name: .customLong("to"), help: ArgumentHelp(L10n.CLI.workspaceToHelp))
        var to: String

        @Option(name: .customLong("kind"), help: ArgumentHelp(L10n.CLI.workspaceKindHelp))
        var kind = "notify"

        @Option(name: .customLong("text"), help: ArgumentHelp(L10n.CLI.workspaceTextHelp))
        var text: String

        @Option(name: .customLong("sender"))
        var sender = "cli"

        func run() throws {
            let target = to
            let kindValue = kind
            let textValue = text
            let senderValue = sender
            let identifier = try WorkspaceMeshCLI.sendMessage(
                sender: senderValue, recipient: target, kind: kindValue, text: textValue,
            )
            print(identifier)
        }
    }

    struct Inbox: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: L10n.CLI.workspaceInboxHelp)

        @Option(name: .customLong("service"))
        var service: String

        @Option(name: .customLong("limit"))
        var limit = 20

        func run() throws {
            let serviceID = service
            let maxItems = max(0, limit)
            let cards = try WorkspaceMeshCLI.listCards()
            guard let card = cards.first(where: { $0.id == serviceID }) else {
                throw ValidationError("service not found: \(serviceID)")
            }
            let directory = URL(fileURLWithPath: card.endpoint)
            let names =
                (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasSuffix(".json") }
                .sorted(by: >)
                .prefix(maxItems) ?? []
            for name in names {
                let file = directory.appendingPathComponent(name)
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    print(text)
                }
            }
        }
    }
}
