import Foundation

/// Implements `utility -a <cmd>`: agent parasitic mode.
///
/// Flow:
/// 1. Ensure `.utility/deps.sqlite` exists → auto-init if missing
/// 2. Full scan → catch changes outside watcher lifetime
/// 3. Start FSEvents file watcher (background, stack-based coalescing)
/// 4. Spawn agent subprocess with stdin/stdout/stderr passthrough
/// 5. On agent exit → stop watcher → exit
enum AgentRunner {
    /// 当前 Agent 子进程 PID（供信号处理清理用）
    static var childPID: Int32 = 0

    /// Entry point called from UtilityCLI.run().
    static func run(agentCommand: String, projectDir: String?) throws {
        let projectPath = projectDir.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.currentDirectoryPath

        // 0. 清理 T 状态（stopped）的残留进程
        try cleanupStaleAgents()
        installSignalHandlers()

        // 1. Ensure deps.sqlite exists
        let dbPath = try prepareDatabase(projectPath: projectPath)
        let isFirstInit = !FileManager.default.fileExists(atPath: dbPath)

        // 2. Scan (first init or full re-sync)
        if isFirstInit {
            print("📦 未发现依赖图，正在扫描项目...")
            let s = try ProjectScanner.shared.scan(projectPath: projectPath)
            print("   \(s)")
        } else {
            print("📦 全量扫描项目，同步变更...")
            let s = try ProjectScanner.shared.scan(projectPath: projectPath)
            print("   发现 \(s)")
        }

        // 3. Start file watcher
        let watcher = FileWatcher(projectPath: projectPath)
        watcher.start()
        defer { watcher.stop() }

        // 4. Print banner
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

    /// Ensure `.utility` directory exists and return the DB path.
    @discardableResult
    private static func prepareDatabase(projectPath: String) throws -> String {
        let utilityDir = (projectPath as NSString).appendingPathComponent(".utility")
        let dbPath = (utilityDir as NSString).appendingPathComponent(ProjectDatabase.depsFilename)
        if !FileManager.default.fileExists(atPath: utilityDir) {
            try FileManager.default.createDirectory(atPath: utilityDir, withIntermediateDirectories: true)
        }
        return dbPath
    }

    // MARK: - 防重与信号处理

    /// 清理 T 状态（stopped）的残留进程。允许多实例运行。
    private static func cleanupStaleAgents() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [
            "-c",
            "pgrep -f '/Applications/Utility.app/Contents/MacOS/utility -a' | grep -vx $$ | grep -vx $PPID",
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let pids = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        guard !pids.isEmpty else { return }

        for pid in pids {
            if processState(pid: pid)?.contains("T") == true {
                kill(Int32(pid) ?? 0, SIGKILL)
                print("🧹 清理 AgentRunner 残留 (PID: \(pid))")
            }
        }
    }

    private static func processState(pid: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "stat=", "-p", pid]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// 终端会话关闭（SIGHUP）/ 终止（SIGTERM）时清理子进程并退出，防孤儿残留。
    private static func installSignalHandlers() {
        signal(SIGHUP) { _ in
            AgentRunner.terminateChildAndExit(SIGHUP)
        }
        signal(SIGTERM) { _ in
            AgentRunner.terminateChildAndExit(SIGTERM)
        }
    }

    private static func terminateChildAndExit(_ sig: Int32) {
        if childPID > 0 {
            kill(childPID, SIGTERM)
            usleep(200_000)  // 给子进程退出时间，兜底强杀
            kill(childPID, SIGKILL)
        }
        Darwin.exit(128 + sig)
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
            childPID = process.processIdentifier

            // Process default creates a new process group for the child, which puts it
            // in the background — reads from stdin get SIGTTIN → stopped (T state).
            // Move child's process group to the terminal foreground so TUI works.
            tcsetpgrp(STDIN_FILENO, process.processIdentifier)
            // Wake child if it was already stopped by SIGTTIN before tcsetpgrp
            kill(process.processIdentifier, SIGCONT)

            process.waitUntilExit()
            childPID = 0

            // Restore ourselves as the terminal foreground process group
            tcsetpgrp(STDIN_FILENO, getpgrp())
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
