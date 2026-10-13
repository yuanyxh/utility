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
    /// Current Agent child process PID (used by signal handling for cleanup)
    static var childPID: Int32 = 0

    /// Entry point called from UtilityCLI.run().
    static func run(agentCommand: String, projectDir: String?) throws {
        let projectPath = projectDir.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.currentDirectoryPath

        // 0. Clean up leftover processes in T state (stopped)
        try cleanupStaleAgents()
        installSignalHandlers()

        // 1. Ensure deps.sqlite exists
        let dbPath = try prepareDatabase(projectPath: projectPath)
        let isFirstInit = !FileManager.default.fileExists(atPath: dbPath)

        // 2. Scan (first init or full re-sync)
        if isFirstInit {
            print("📦 No dependency graph found, scanning project...")
            let s = try ProjectScanner.shared.scan(projectPath: projectPath)
            print("   \(s)")
        } else {
            print("📦 Full project scan, syncing changes...")
            let s = try ProjectScanner.shared.scan(projectPath: projectPath)
            print("   Found \(s)")
        }

        // 3. Start file watcher
        let watcher = FileWatcher(projectPath: projectPath)
        watcher.start()
        defer { watcher.stop() }

        // 4. Print banner
        print("╔══════════════════════════════════════╗")
        print("║   Utility Agent Mode                ║")
        print("╠══════════════════════════════════════╣")
        print("║  📁 Project: \(projectPath.padding(toLength: 28, withPad: " ", startingAt: 0))║")
        print("║  🗄️  Deps: \(FileManager.default.fileExists(atPath: dbPath) ? "✓" : "✗")                   ║")
        print("║  🤖 Agent: \(agentCommand.prefix(30))║")
        print("╚══════════════════════════════════════╝")
        print()
        fflush(stdout)

        // 4. Spawn agent
        let exitCode = spawnAgent(command: agentCommand, projectPath: projectPath, dbPath: dbPath)

        print()
        print("✅ Agent exited (exit code: \(exitCode))")
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

    // MARK: - Duplicate prevention and signal handling

    /// Clean up leftover processes in T state (stopped). Multiple instances are allowed to run.
    private static func cleanupStaleAgents() throws {
        // Dynamically get the current process path and build the match pattern
        let currentPath = ProcessInfo.processInfo.arguments.first ?? "utility"
        let matchPattern = "\(currentPath) -a"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [
            "-c",
            "pgrep -f '\(matchPattern)' | grep -vx $$ | grep -vx $PPID",
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
                print("🧹 Cleaned up AgentRunner leftovers (PID: \(pid))")
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

    /// On terminal session close (SIGHUP) / termination (SIGTERM) clean up the child process and exit, preventing orphan leftovers.
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
            usleep(200_000) // give the child time to exit, force-kill as a backstop
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
            print("❌ Failed to start Agent: \(error.localizedDescription)")
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
