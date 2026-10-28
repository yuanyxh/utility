import Foundation

/// Unified entry point for executing Python scripts.
///
/// For every gateway entry module (see `GatewayEntry`), venv location, bootstrap arguments,
/// environment variable construction, one-shot execution, and the resident daemon are all
/// consolidated here; callers no longer each implement their own.
/// Business decisions (state semantics, event broadcast, reuse probing, notification) remain with the
/// composing parties (MCPProcessManager / TokenProxyManager); this class only provides the generic skeleton.
enum PythonScriptRunner {
    // MARK: - venv path (single source of truth)

    /// Path to the Python venv where MCP dependencies are installed.
    /// Auto-detect the system Python version and construct the corresponding venv path.
    /// Created by `GatewayInstaller` on first launch (venv + the bundled gateway wheel)
    /// Lazily resolved once and cached.
    ///
    /// Resolution spawns a child process (`/usr/bin/env python3 --version`) and synchronously waits
    /// for it to exit, and this property is called from many places (`resolvePython`, `shellCommand`,
    /// `pythonCheck`, etc.) -- making it a computed property that re-resolves each time would make every
    /// call point pay for a process creation and blocking wait for nothing. The venv path does not change
    /// during the process lifetime, so caching is safe.
    static let pythonVenvPath: String = resolveVenvPath()

    /// `~/.config/utility/mcp-venv` — the installer needs it before the interpreter exists.
    static let venvDir: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/utility/mcp-venv")
        .path

    private static func resolveVenvPath() -> String {
        let venvDir = venvDir

        // Detect the system Python version (e.g. python3.12)
        if let version = detectPythonVersion() {
            // Try the exact versioned path: ~/.config/utility/mcp-venv/bin/python3.12
            let versionedPath = "\(venvDir)/bin/python\(version)"
            if FileManager.default.fileExists(atPath: versionedPath) {
                return versionedPath
            }
        }

        // Fall back to the generic path: ~/.config/utility/mcp-venv/bin/python3
        return "\(venvDir)/bin/python3"
    }

    /// Detect the system Python version number (e.g. "12"); returns nil on failure
    private static func detectPythonVersion() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", "--version"]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Parse "Python 3.12.1" -> "12"
        let components = output.components(separatedBy: " ").last?.components(separatedBy: ".")
        return components?.first
    }

    /// True when the gateway can be imported: a sibling checkout provides sources, or the venv
    /// holds a verified install. A bare venv is not enough — the wheel install may have failed
    /// offline, and registering tasks against it would fail every run.
    static var isGatewayAvailable: Bool {
        GatewayResources.developmentSourceRoot() != nil || GatewayInstaller.isInstalled
    }

    /// Resolve an available python executable: prefer the mcp venv, fall back to the system python3 when missing.
    static func resolvePython() -> String? {
        if FileManager.default.fileExists(atPath: pythonVenvPath) {
            return pythonVenvPath
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-c", "command -v python3 || command -v python"]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Entry module resolution (single source of truth)

    /// `-c` code that runs `main()` of a gateway entry module, so the host never needs a
    /// script path inside the bundle. `sys.exit` propagates the module's return code —
    /// without it a failing task still exits 0 and the scheduler counts it as success.
    static func bootstrapCode(for module: String) -> String {
        "import sys; from \(module) import main; sys.exit(main())"
    }

    static func bootstrapArguments(for module: String) -> [String] {
        ["-c", bootstrapCode(for: module)]
    }

    // MARK: - Environment variables (single source of truth)

    /// `runtime.selfManaged`: the Python side reads config.yaml itself, so config-surface env is skipped.
    /// Runtime-only values (paths, ports, proxy, timeouts) are still injected.
    static var isSelfManaged: Bool {
        ConfigManager.shared.config.runtime.selfManaged
    }

    /// Common base environment variables: AI config + data directory + notes directory + unbuffered output + username + timeout config.
    /// Script-specific variables (MCP_PORT / MODEL_PROXY_* / QDRANT_PATH, etc.) are appended by callers via
    /// `environment(overrides:)`, keeping "Swift-side env consolidation".
    static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // Forbid writing __pycache__: scripts ship inside the .app bundle and are signed; generating .pyc at
        // runtime adds files inside the bundle, breaking the signature seal (codesign reports sealed resource missing)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["UTILITY_DATA_DIR"] = AppPaths.configDir.path

        // Current system username (passed to the Python layer's DEFAULT_USER_ID)
        let username = NSUserName()
        if !username.isEmpty { env["UTILITY_USER_ID"] = username }

        // Timeout config (read from GeneralConfig)
        let general = ConfigManager.shared.config.general
        if general.httpTimeout > 0 {
            env["SERVER_TIMEOUT"] = String(general.httpTimeout)
        }
        if general.aiTimeout > 0 {
            env["AGENT_TIMEOUT"] = String(Int(general.aiTimeout))
        }

        // System proxy config
        if general.proxyEnabled, let proxyURL = URLSessionManager.shared.systemProxyURL {
            let proxyString = proxyURL.absoluteString
            env["HTTP_PROXY"] = proxyString
            env["HTTPS_PROXY"] = proxyString
            env["http_proxy"] = proxyString
            env["https_proxy"] = proxyString
        }

        // `runtime.selfManaged` hands config reading to the Python side (`config_loader`).
        if !isSelfManaged {
            // ai config + language (values share the same source as the `.sh` tasks, see aiEnvironment())
            for (key, value) in aiEnvironment() {
                env[key] = value
            }
            for (key, value) in knowledgeEnvironment() {
                env[key] = value
            }
            for (key, value) in noteEnvironment() {
                env[key] = value
            }
            for (key, value) in logEnvironment() {
                env[key] = value
            }

            // mcp path config (token_proxy also needs NOTES_DIR, so it lives in the common layer)
            if let notesDir = resolvedNotesDir() {
                env["NOTES_DIR"] = notesDir
            }
        }
        for (key, value) in languageEnvironment() {
            env[key] = value
        }
        for (key, value) in gatewayPathEnvironment() {
            env[key] = value
        }
        // Google search shells out to this binary; the provider is injected as a command.
        if let binary = Bundle.main.executableURL?.path, !binary.isEmpty {
            env["GATEWAY_SEARCH_PROVIDERS"] = gatewaySearchProviders(binary: binary)
        }
        // Development without installing the wheel: point Python at the sibling checkout.
        if let devRoot = GatewayResources.developmentSourceRoot() {
            env["PYTHONPATH"] = devRoot
        }
        return env
    }

    /// Search providers injected into the gateway. The gateway never discovers this binary itself.
    private static func gatewaySearchProviders(binary: String) -> String {
        let command = [binary, "websearch", "--query", "{q}", "--limit", "{limit}"]
        let payload: [String: Any] = [
            "google": ["command": command, "timeout": 25]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }

    // MARK: - Cross-language env values (shared by the service process and `.sh` tasks)

    /// AI-related env: key / baseURL / model / llmTimeout / language.
    ///
    /// Extracted into one place because **cross-language env has two injection points**: the service process
    /// goes through `baseEnvironment()`, while the internal `.sh` scheduled tasks go through
    /// `shellCommand(environmentOverrides:)`. When the value logic is written twice, a newly added env only
    /// lands in one of the two, showing up as "config takes effect in the service process, but scheduled tasks
    /// silently fall back to the default" -- `AI_LLM_TIMEOUT` and `UTILITY_LANG` leaked exactly like this once:
    /// scheduled summaries always used a 120s timeout (and `ai.llmTimeout`'s consumers happen to all be on the
    /// summarize path), and the English UI still used Chinese prompts.
    static func aiEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        let ai = ConfigManager.shared.config.ai
        if !ai.apiKey.isEmpty { env[EnvKeys.aiAPIKey] = ai.apiKey }
        if !ai.baseURL.isEmpty { env["SUMMARY_API_URL"] = ai.baseURL }
        if !ai.model.isEmpty { env["SUMMARY_MODEL"] = ai.model }
        // 0 / negative = use the built-in default, do not inject (the Python side `config.llm_timeout()` falls back by the same convention).
        // **Keep the fraction**: `String(Int(...))` turns 0.5 into "0", and Python treats 0 as "not configured" and
        // falls back to the default 120s -- Swift thinks it was injected, Python thinks it was not configured; the same 0 means opposite things in the two places.
        if ai.llmTimeout > 0 { env[EnvKeys.aiLLMTimeout] = String(ai.llmTimeout) }
        return env
    }

    /// UI/prompt language resolved from config plus the system preference.
    ///
    /// Injected even under `runtime.selfManaged`: it is a derived value, and the Python
    /// side cannot resolve "follow the system" from `general.language` alone.
    static func languageEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        env[EnvKeys.utilityLang] = L10n.resolvedLanguage(
            configured: ConfigManager.shared.config.general.language,
        )
        return env
    }

    /// Knowledge panel seeds and pool budgets, serialized for the Python refill script.
    /// Extracted for the same reason as `aiEnvironment()`: there are **two injection points**
    /// (`baseEnvironment()` and `taskEnvironmentOverrides()`), and a value written twice silently diverges.
    static func knowledgeEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        let knowledge = ConfigManager.shared.config.knowledge
        if !knowledge.topics.isEmpty {
            let seeds = knowledge.topics.map {
                [
                    "name": $0.name, "kind": $0.kind,
                    "scope": $0.scope, "exclude": $0.exclude,
                ]
            }
            if let json = encodeJSON(seeds) {
                env[EnvKeys.knowledgeTopics] = json
            }
        }
        env[EnvKeys.knowledgeTopicTarget] = String(knowledge.poolTargetTopic)
        env[EnvKeys.knowledgeMaxFailStreak] = String(knowledge.maxFailStreak)
        env[EnvKeys.knowledgeRetentionDays] = String(knowledge.retentionDays)
        return env
    }

    /// Note scanning rules (`mcp.noteExcludeDirs` / `mcp.noteExtensions`).
    /// Empty lists are not injected -- the Python side then skips nothing / uses its built-in extensions.
    static func noteEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        guard let mcp = ConfigManager.shared.config.mcp else { return env }
        if !mcp.noteExcludeDirs.isEmpty, let json = encodeJSON(mcp.noteExcludeDirs) {
            env[EnvKeys.noteExcludeDirs] = json
        }
        if !mcp.noteExtensions.isEmpty, let json = encodeJSON(mcp.noteExtensions) {
            env[EnvKeys.noteExtensions] = json
        }
        return env
    }

    /// Log rotation limits, same source as `DebugLogRotate` (`general.logMaxSize` / `logBackupCount`).
    static func logEnvironment() -> [String: String] {
        let general = ConfigManager.shared.config.general
        var env: [String: String] = [:]
        if general.logMaxSize > 0 {
            env[EnvKeys.logMaxSize] = String(general.logMaxSize)
        }
        if general.logBackupCount > 0 {
            env[EnvKeys.logBackupCount] = String(general.logBackupCount)
        }
        return env
    }

    private static func encodeJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Gateway data, cache and config roots; without these it falls back to its own defaults.
    static func gatewayPathEnvironment() -> [String: String] {
        [
            "GATEWAY_HOME": AppPaths.configDir.path,
            "GATEWAY_CACHE": AppPaths.cacheDir.path,
            "GATEWAY_CONFIG": AppPaths.configFile.path,
        ]
    }

    /// Knowledge base notes directory (empty config -> `<config domain>/notes`). Also shared by the two injection points.
    static func resolvedNotesDir() -> String? {
        guard let mcp = ConfigManager.shared.config.mcp else { return nil }
        // Empty string = use the default path
        return mcp.knowledgeBasePath.isEmpty
            ? AppPaths.configDir.appendingPathComponent("notes").path
            : (mcp.knowledgeBasePath as NSString).expandingTildeInPath
    }

    /// The env the internal `.sh` tasks need inlined (**the minimal common set for the service process and scheduled tasks**).
    ///
    /// The difference from `baseEnvironment()` is **intentional**: `.sh` runs through `/bin/bash -c`, and inlining all of
    /// baseEnvironment (inherited environment, proxy settings, etc.) into the command string both pollutes it and can be
    /// truncated if a value contains spaces, so only the keys the script truly needs are listed here. But **the values must
    /// share the same source as baseEnvironment** (`aiEnvironment()` / `resolvedNotesDir()`) -- when adding a cross-language
    /// env, both places must be handled.
    /// `MEMORY_SERVER_URL` / `SUMMARY_EXCLUDE_TAGS` are unique to the `.sh` side and passed by the caller.
    static func taskEnvironmentOverrides(
        memoryServerURL: String,
        excludeTags: String,
    ) -> [String: String] {
        var overrides: [String: String] = [:]
        if !isSelfManaged {
            overrides = aiEnvironment()
            for (key, value) in knowledgeEnvironment() {
                overrides[key] = value
            }
            for (key, value) in noteEnvironment() {
                overrides[key] = value
            }
            for (key, value) in logEnvironment() {
                overrides[key] = value
            }
            if let notesDir = resolvedNotesDir() { overrides["NOTES_DIR"] = notesDir }
            overrides["SUMMARY_EXCLUDE_TAGS"] = excludeTags
        }
        for (key, value) in languageEnvironment() {
            overrides[key] = value
        }
        overrides["PYTHONDONTWRITEBYTECODE"] = "1" // same as baseEnvironment: do not write .pyc inside the signed bundle
        overrides["UTILITY_DATA_DIR"] = AppPaths.configDir.path
        for (key, value) in gatewayPathEnvironment() {
            overrides[key] = value
        }
        overrides["MEMORY_SERVER_URL"] = memoryServerURL
        if let binary = Bundle.main.executableURL?.path, !binary.isEmpty {
            overrides["GATEWAY_SEARCH_PROVIDERS"] = gatewaySearchProviders(binary: binary)
        }
        if let devRoot = GatewayResources.developmentSourceRoot() {
            overrides["PYTHONPATH"] = devRoot
        }
        return overrides
    }

    /// baseEnvironment + script-specific overrides.
    static func environment(overrides: [String: String]) -> [String: String] {
        var env = baseEnvironment()
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }

    // MARK: - Shell command construction (for TaskScheduler .sh tasks)

    /// Single-quote a value for `/bin/bash -c` (embedded single quotes are escaped).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build a shell command string: `KEY=VALUE ... pythonVenv script args`.
    /// TaskScheduler's .sh runs through `/bin/bash -c`; the child process inherits the app's restricted PATH and
    /// TaskExecConfig.toProcess() does not set environment variables, so the environment must be inlined as `KEY=VALUE` prefixes.
    ///
    /// Note: only inline the variables the caller explicitly provides (environmentOverrides); do not stuff in
    /// baseEnvironment() -- it starts from ProcessInfo.processInfo.environment and would bring in every inherited
    /// environment variable, polluting the command and carrying values with spaces/special characters. bash itself
    /// inherits the parent process environment, so only the overrides the script needs are injected here (consistent
    /// with the existing call behavior).
    static func shellCommand(
        entry: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
    ) -> String {
        var parts: [String] = []
        // Sorting keeps the output stable (KEY order does not affect bash semantics)
        for key in environmentOverrides.keys.sorted() {
            // Quoting is required: bash strips the double quotes of a JSON array
            // (`["a","b"]` -> `[a,b]`) and splits values containing spaces.
            parts.append("\(key)=\(shellQuote(environmentOverrides[key] ?? ""))")
        }
        parts.append(pythonVenvPath)
        parts.append("-c")
        parts.append(shellQuote(bootstrapCode(for: entry)))
        parts.append(contentsOf: arguments)
        return parts.joined(separator: " ")
    }

    // MARK: - One-shot execution (AST batch / single file)

    /// Execute the script with venv python, writing optional stdin and reading/storing stdout as it goes (avoiding the
    /// pipe buffer filling up and blocking the child process); on timeout, kill it and throw.
    /// - Returns: the complete stdout bytes.
    static func runCaptureOutput(
        module: String,
        arguments: [String] = [],
        stdin: Data? = nil,
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        shouldCancel: (() -> Bool)? = nil,
    ) throws -> Data {
        guard let pythonPath = resolvePython() else {
            throw PythonProcessError.pythonUnavailable
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = bootstrapArguments(for: module) + arguments
        // Without this the child inherits the GUI process's launchd environment, which has no
        // AI_API_KEY / UTILITY_DATA_DIR — the script then runs "successfully" and produces nothing.
        if let environment {
            proc.environment = environment
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        // Read and store stdout as it goes: batch AST output can exceed the pipe buffer (64KB), and not reading
        // while waiting would cause the child process to fill up and block, never exit, and be wrongly killed by the timeout.
        var outputData = Data()
        let outputLock = NSLock()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputLock.lock()
            outputData.append(chunk)
            outputLock.unlock()
        }

        do {
            try proc.run()

            if let stdin {
                inputPipe.fileHandleForWriting.write(stdin)
            }
            inputPipe.fileHandleForWriting.closeFile()

            // Wait with timeout
            let deadline = DispatchTime.now() + timeout
            while proc.isRunning, .now() < deadline {
                // Poll-based cancellation (used by the knowledge refill to abort on system sleep):
                // a few seconds of latency is irrelevant next to the LLM calls it avoids.
                if shouldCancel?() == true {
                    kill(proc.processIdentifier, SIGKILL)
                    throw PythonProcessError.cancelled(script: module)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Stop the async read and synchronously drain the rest (the handler may not have read the tail data at the moment of exit)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                throw PythonProcessError.timeout(script: module)
            }
            while let chunk = outputPipe.fileHandleForReading.availableData as Data?, !chunk.isEmpty {
                outputLock.lock()
                outputData.append(chunk)
                outputLock.unlock()
            }

            return outputData
        } catch let error as PythonProcessError {
            throw error
        } catch {
            throw PythonProcessError.launchFailed(error.localizedDescription)
        }
    }
}

enum PythonProcessError: Error, LocalizedError {
    case pythonUnavailable
    case timeout(script: String)
    case cancelled(script: String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            "No usable Python (both mcp-venv and system python3 are unavailable)"
        case let .timeout(script):
            "Script \(script) execution timed out"
        case let .cancelled(script):
            "Script \(script) execution cancelled"
        case let .launchFailed(msg):
            "Python process failed to launch: \(msg)"
        }
    }
}
