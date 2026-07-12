import Foundation

/// Implements `utility -a <cmd>`: agent parasitic mode.
///
/// Flow:
/// 1. Ensure `.utility/deps.sqlite` exists → auto-init if missing
/// 2. Start FSEvents file watcher (background, 3s debounce)
/// 3. Spawn agent subprocess with stdin/stdout/stderr passthrough
/// 4. On agent exit → stop watcher → exit
enum AgentRunner {
    /// Entry point called from UtilityCLI.run().
    static func run(agentCommand: String, projectDir: String?) throws {
        let projectPath = projectDir.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.currentDirectoryPath

        // 1. Ensure deps.sqlite exists
        let dbPath = try ensureDatabase(projectPath: projectPath)

        // 2. Start file watcher
        let watcher = FileWatcher(projectPath: projectPath)
        watcher.start()
        defer { watcher.stop() }

        // 3. Print banner
        print("╔══════════════════════════════════════╗")
        print("║   Utility Agent Mode                ║")
        print("╠══════════════════════════════════════╣")
        print("║  📁 项目: \(projectPath.padding(toLength: 28, withPad: " ", startingAt: 0))║")
        print("║  🗄️  依赖图: \(FileManager.default.fileExists(atPath: dbPath) ? "✓" : "✗")                   ║")
        print("║  🤖 Agent: \(agentCommand.prefix(30))║")
        print("╚══════════════════════════════════════╝")
        print()
        fflush(stdout)

        // 4. Spawn agent
        let exitCode = spawnAgent(command: agentCommand, projectPath: projectPath, dbPath: dbPath)

        print()
        print("✅ Agent 已退出 (exit code: \(exitCode))")
        Darwin.exit(exitCode)
    }

    // MARK: - Database

    /// Check for `.utility/deps.sqlite`, auto-scan if missing.
    @discardableResult
    private static func ensureDatabase(projectPath: String) throws -> String {
        let dbPath = (projectPath as NSString).appendingPathComponent(".utility/deps.sqlite")

        guard !FileManager.default.fileExists(atPath: dbPath) else {
            return dbPath
        }

        print("📦 未发现依赖图，正在扫描项目...")
        let summary = try ProjectScanner.shared.scan(projectPath: projectPath)
        print("   \(summary)")
        return dbPath
    }

    // MARK: - Agent spawn

    /// Spawn agent as a child process with full TUI passthrough.
    private static func spawnAgent(command: String, projectPath: String, dbPath: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        // Passthrough TUI
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        let stderr = FileHandle.standardError
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Set environment for the agent
        var env = ProcessInfo.processInfo.environment
        env["UTILITY_PROJECT_DIR"] = projectPath
        env["UTILITY_PROJECT_DB"] = dbPath
        if let port = ConfigManager.shared.config.mcp?.port {
            env["MCP_PORT"] = String(port)
        }
        // `CLAUDE_CODE_EXTRA_TOOLS` is inspired from `claude_code_extra_tools` from Claude Code
        // This lets any CLI agent discover project tools automatically
        env["MINO_BRAIN_MCP_PORT"] = env["MCP_PORT"]

        // Restore terminal to raw mode for TUI apps (like claude, aider, etc.)
        // The child process handles this, but we ensure the terminal is in the right state
        process.environment = env

        signal(SIGINT, SIG_IGN) // Let child handle Ctrl-C

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("❌ 启动 Agent 失败: \(error.localizedDescription)")
            return 1
        }

        return process.terminationStatus
    }
}

// MARK: - String padding helper

private extension String {
    func padding(toLength length: Int, withPad pad: String, startingAt _: Int) -> String {
        if count >= length { return String(prefix(length - 1)) + "…" }
        return self + String(repeating: pad, count: length - count)
    }
}
