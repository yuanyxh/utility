import AppKit
import Foundation

/// Manages the Python MCP server subprocess lifecycle.
/// Starts on app launch, restarts on crash (maxRestarts), stops on app quit.
/// All config is read live from ConfigManager; stale values are never cached.
/// Process lifecycle (start / crash restart / health check / stop) is delegated
/// to PythonDaemon; this class owns the business decisions: State semantics,
/// event broadcast, reuse probing, crash notification, and the Python pre-flight check.
final class MCPProcessManager {
    static let shared = MCPProcessManager()

    enum State: String {
        case stopped, initializing, running, restarting, crashed
    }

    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            MCPMenuManager.shared.updateState(state)
            // Broadcast for menu bar integration (P4)
            EventBus.shared.publish("mcp_state_changed", payload: state.rawValue)
        }
    }

    private var daemon: PythonDaemon?

    // Pre-flight cache (config is not cached, but the Python check result is —
    // the Python version does not change at runtime)
    private var cachedServerPath: String?
    private var pythonChecked = false
    private var pythonAvailable = false

    /// Config read (live, not cached)
    private var mcpConfig: MCPConfig? {
        ConfigManager.shared.config.mcp
    }

    /// Auto-detected port (used only when the `port` config is 0).
    ///
    /// **Must be cached**: probing works by a bind test, and once the MCP service
    /// is up it holds this port itself — probing again would skip it and return
    /// the next one (9001 → 9002). This used to be a computed property that
    /// re-probed on every access, so any runtime read returned a drifting value.
    private var cachedPort: Int?
    private let portLock = NSLock()

    /// The port actually used by this run. Both the server side (the daemon's
    /// launch arguments and environment) and consumers (`MCPClient`, usage
    /// queries) read from here, keeping both sides pointed at the same port.
    var currentPort: Int {
        let configured = mcpConfig?.port ?? 0
        // An explicitly configured port is always authoritative and bypasses the
        // cache — config changes should take effect immediately
        if configured > 0 { return configured }

        portLock.lock()
        defer { portLock.unlock() }
        if let cachedPort { return cachedPort }
        let detected = PortProbe.detectAvailable(startingFrom: PortProbe.Base.mcp)
        cachedPort = detected
        return detected
    }

    private var maxRestarts: Int {
        mcpConfig?.maxRestarts ?? 3
    }

    private var restartDelaySec: Double {
        Double(mcpConfig?.restartDelayMs ?? 2000) / 1000.0
    }

    /// Script-specific environment variables (the common part comes from
    /// PythonScriptRunner.baseEnvironment()). Read live — PythonDaemon calls
    /// this property through the environment closure on every launch.
    private var serverEnvironment: [String: String] {
        var overrides: [String: String] = [:]
        overrides["MCP_PORT"] = String(currentPort)

        // MEMORY_SERVER_URL: summarize.py uses this variable to reach the MCP service
        overrides["MEMORY_SERVER_URL"] = HTTP.localBaseURL(port: currentPort)

        // MCP path config (empty string = use the default path)
        if let mcp = mcpConfig {
            // Empty string = use the default path ~/.config/utility/data/qdrant/
            let qdrantPath: String = if mcp.qdrantPath.isEmpty {
                AppPaths.configDir
                    .appendingPathComponent("data/qdrant").path
            } else {
                (mcp.qdrantPath as NSString).expandingTildeInPath
            }
            overrides["QDRANT_PATH"] = qdrantPath

            // Empty string = use the default path ~/.cache/utility/fastembed/
            let fastembedCachePath: String = if mcp.fastembedCacheDir.isEmpty {
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache/utility/fastembed").path
            } else {
                (mcp.fastembedCacheDir as NSString).expandingTildeInPath
            }
            overrides["FASTEMBED_CACHE_PATH"] = fastembedCachePath

            // Empty string = use the built-in default model
            if !mcp.embedderModel.isEmpty {
                overrides["EMBEDDER_MODEL"] = mcp.embedderModel
            }

            // Search synonym expansion table: both keys and values are user-defined
            // and cannot be modelled by a fixed struct, so the whole thing is
            // serialized and passed through. Merging is done in one place on the
            // Python side — writing the merge logic twice would eventually produce
            // an inexplicable "Swift overrode it, Python appended it" divergence.
            if let json = Self.synonymsJSON(mcp.synonyms) {
                overrides[Self.synonymsEnvKey] = json
            }

            // Tool argument defaults: tool and argument names come from the code
            // side and only values are user-defined; merging (built-in +
            // incremental) likewise happens in one place on the Python side.
            if let json = Self.toolDefaultsJSON(mcp.toolDefaults) {
                overrides[Self.toolDefaultsEnvKey] = json
            }
        }
        return PythonScriptRunner.environment(overrides: overrides)
    }

    /// Env name for the synonym table (a cross-language contract; the Python
    /// side's `synonyms.SYNONYMS_ENV_KEY` holds the same value, cross-asserted
    /// by `scripts/check-router-config-contract.py`).
    static let synonymsEnvKey = "MCP_SYNONYMS"

    /// Synonym table → JSON; an empty table returns nil (not injected; the Python
    /// side falls back to built-in defaults).
    static func synonymsJSON(_ synonyms: [String: String]) -> String? {
        guard !synonyms.isEmpty,
              let data = try? JSONEncoder().encode(synonyms),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    /// Env name for tool defaults (a cross-language contract; the Python side's
    /// `tool_defaults.TOOL_DEFAULTS_ENV_KEY` holds the same value, cross-asserted
    /// by `scripts/check-router-config-contract.py`).
    static let toolDefaultsEnvKey = "MCP_TOOL_DEFAULTS"

    /// Tool defaults → JSON; an empty table returns nil (not injected; the Python
    /// side falls back to built-in defaults).
    static func toolDefaultsJSON(_ defaults: [String: [String: Int]]) -> String? {
        guard !defaults.isEmpty,
              let data = try? JSONEncoder().encode(defaults),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    /// Reset the pre-flight cache (called after a config reload; the next start re-checks).
    private func resetPrefetch() {
        cachedServerPath = nil
        pythonChecked = false
        pythonAvailable = false
    }

    // MARK: - Public API

    /// - Parameter reuseIfHealthy: true on cold start (app launch) — if the port
    ///   is already held by a healthy server, reuse it (an orphaned process
    ///   reparented to launchd still listens on the port, so a fresh spawn would
    ///   fail to bind). forceRestart/restart pass false — there the user expects
    ///   a real restart to apply the new config, and reusing the old process
    ///   would silently ignore it.
    func start(reuseIfHealthy: Bool = true) {
        guard mcpConfig?.enabled ?? false else {
            log("[MCP] Disabled by config, skipping")
            return
        }

        // Re-check on every start (config may have changed)
        guard pythonCheck() else {
            state = .crashed
            return
        }

        guard let serverPath = findServerScript() else {
            log("[MCP] server.py not found in bundle")
            state = .crashed
            return
        }

        let daemon = ensureDaemon(scriptPath: serverPath)
        state = .initializing
        // Reuse when the port is held by a healthy server, avoiding duplicate
        // spawns that race for the port
        daemon.start(reuseIfHealthy: reuseIfHealthy)
    }

    /// Force a restart (called on config reload, regardless of current state).
    /// Delegates to PythonDaemon.forceRestart(): stop the old process → wait for
    /// it to die → actually spawn. port/scriptPath are read live through closures,
    /// so a new config applies without rebuilding the daemon.
    func forceRestart() {
        log("[MCP] Force restart (config reload)")
        resetPrefetch()
        guard let daemon else {
            log("[MCP] No daemon, cold start instead")
            start(reuseIfHealthy: false)
            return
        }
        daemon.forceRestart()
    }

    func stop() {
        daemon?.stop()
    }

    func restart() {
        stop()
        start(reuseIfHealthy: false)
    }

    // MARK: - Pre-flight checks

    private func pythonCheck() -> Bool {
        if pythonChecked { return pythonAvailable }
        pythonChecked = true

        // 1. Check if venv exists
        let venvPython = PythonScriptRunner.pythonVenvPath
        guard FileManager.default.fileExists(atPath: venvPython) else {
            // 2. Check if Homebrew python3.12 is available
            let brewTask = Process()
            brewTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // Probe for any python3 rather than a pinned minor version: looking
            // for python3.12 when the user installed 3.13 would falsely report
            // "not installed"
            brewTask.arguments = ["bash", "-c", "command -v python3"]
            let brewPipe = Pipe()
            brewTask.standardOutput = brewPipe
            brewTask.standardError = FileHandle.nullDevice
            var brewPython: String? = nil
            if (try? brewTask.run()) != nil {
                brewTask.waitUntilExit()
                if brewTask.terminationStatus == 0 {
                    let data = brewPipe.fileHandleForReading.readDataToEndOfFile()
                    brewPython = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if brewPython == nil {
                let msg = L10n.Notify.mcpEnvPythonMissing
                log("[MCP] ❌ \(msg)")
                notify(L10n.Notify.mcpEnvCheckTitle, msg)
            } else {
                let reqPath = "Sources/MCPScripts/requirements.txt"
                let steps = """
                Create the virtual environment:
                  python3 -m venv ~/.config/utility/mcp-venv
                  ~/.config/utility/mcp-venv/bin/pip install -r \(reqPath)
                """
                log("[MCP] ❌ Virtual environment not ready\n\(steps)")
                notify(L10n.Notify.mcpEnvCheckTitle, L10n.Notify.mcpEnvVenvMissing)
            }
            pythonAvailable = false
            return false
        }

        // 3. venv exists, verify it works
        let task = Process()
        task.executableURL = URL(fileURLWithPath: venvPython)
        task.arguments = ["--version"]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            pythonAvailable = task.terminationStatus == 0
        } catch {
            pythonAvailable = false
        }
        if !pythonAvailable {
            log("[MCP] ❌ Virtual environment Python unusable: \(venvPython)")
        }
        return pythonAvailable
    }

    private func findServerScript() -> String? {
        PythonScriptRunner.findScript(named: PythonScripts.server)
    }

    // MARK: - Daemon assembly

    /// Create (or reuse) the PythonDaemon and wire up state callbacks.
    /// The daemon lifecycle (start / crash restart / health check / stop) is
    /// self-managed by PythonDaemon.
    private func ensureDaemon(scriptPath: String) -> PythonDaemon {
        if let daemon { return daemon }

        let config = PythonDaemon.Config(
            scriptPath: { [weak self] in
                self?.findServerScript() ?? scriptPath
            },
            port: { [weak self] in
                // The fallback value shares its source with PortProbe.Base.mcp,
                // so the two literals cannot drift apart
                self?.currentPort ?? PortProbe.Base.mcp
            },
            healthPath: "/health",
            service: "mino-brain", // Validate the service field to avoid reusing another service on the same port
            readySignals: ["Application startup complete", "Uvicorn running on"],
            maxRestarts: maxRestarts,
            restartDelaySec: restartDelaySec,
            environment: { [weak self] in
                self?.serverEnvironment ?? [:]
            },
            logTag: "MCP",
        )
        let daemon = PythonDaemon(config: config)
        daemon.onStateChange = { [weak self] daemonState in
            self?.applyDaemonState(daemonState)
        }
        daemon.onMaxRestarts = { [weak self] _ in
            self?.notifyCrash()
        }
        self.daemon = daemon
        return daemon
    }

    /// Map PythonDaemon's generic state onto MCP's own 5-state State and broadcast it.
    private func applyDaemonState(_ daemonState: PythonDaemon.State) {
        switch daemonState {
        case .starting:
            state = .initializing
        case .running:
            state = .running
        case .restarting:
            state = .restarting
        case .crashed:
            state = .crashed
        case .stopped:
            state = .stopped
        }
    }

    private func notify(_ title: String, _ body: String) {
        EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(title: title, body: body))
    }

    private func notifyCrash() {
        notify(L10n.Notify.mcpCrashedTitle, L10n.Notify.mcpCrashed(count: maxRestarts))
    }
}

// MARK: - Logger

private func log(_ msg: String) {
    debugLog(msg)
}
