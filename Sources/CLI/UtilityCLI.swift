import ArgumentParser
import Foundation

/// Root CLI entry point.
/// Usage: utility <subcommand> [options]
///   utility rss --fetch
///   utility init --path <path>
///   utility -a "claude -p 'analyze this module'"
///   utility --dir ~/myapp -a claude
struct UtilityCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "utility",
        abstract: "macOS desktop toolkit CLI",
        subcommands: [
            RSSCommand.self,
            InitCommand.self,
        ],
        defaultSubcommand: nil,
    )

    // ── Agent mode flags (only effective when there is no subcommand) ──

    @Option(name: .shortAndLong,
            help: ArgumentHelp("Agent command, e.g. \"claude -p 'analyze module'\" or \"aider --model sonnet\""))
    var agent: String?

    @Option(name: .customLong("dir"),
            help: ArgumentHelp("Project directory path (default: current directory)"))
    var projectDir: String?

    func run() throws {
        guard let cmd = agent, !cmd.isEmpty else {
            throw CleanExit.helpRequest()
        }
        try AgentRunner.run(agentCommand: cmd, projectDir: projectDir)
    }
}
