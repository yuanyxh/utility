import ArgumentParser
import Foundation

/// Root CLI entry point.
/// Usage: utility <subcommand> [options]
///   utility rss --fetch
///   utility init --path <path>
///   utility -a "claude -p '分析这个模块'"
///   utility --dir ~/myapp -a claude
struct UtilityCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "utility",
        abstract: "macOS 桌面工具集 CLI",
        subcommands: [
            RSSCommand.self,
            InitCommand.self,
        ],
        defaultSubcommand: nil
    )

    // ── Agent mode flags (仅无子命令时生效) ──

    @Option(name: .shortAndLong,
            help: ArgumentHelp("Agent 命令，如 \"claude -p '分析模块'\" 或 \"aider --model sonnet\""))
    var agent: String?

    @Option(name: .customLong("dir"),
            help: ArgumentHelp("项目目录路径（默认：当前目录）"))
    var projectDir: String?

    func run() throws {
        guard let cmd = agent, !cmd.isEmpty else {
            throw CleanExit.helpRequest()
        }
        try AgentRunner.run(agentCommand: cmd, projectDir: projectDir)
    }
}
