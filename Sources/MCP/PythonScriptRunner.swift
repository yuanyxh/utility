import Foundation

/// Unified entry point for executing Python scripts.
///
/// For all py scripts (see the list in `PythonScripts`, corresponding to `Sources/MCPScripts/*.py`), venv
/// location, script path resolution, environment variable construction, one-shot execution, and the resident
/// daemon are all consolidated here; callers no longer each implement their own.
/// Business decisions (state semantics, event broadcast, reuse probing, notification) remain with the
/// composing parties (MCPProcessManager / TokenProxyManager); this class only provides the generic skeleton.
enum PythonScriptRunner {
    // MARK: - venv path (single source of truth)

    /// Path to the Python venv where MCP dependencies are installed.
    /// Auto-detect the system Python version and construct the corresponding venv path.
    /// Created by: `python3.X -m venv ~/.config/utility/mcp-venv && pip install -r requirements.txt`
    /// Lazily resolved once and cached.
    ///
    /// Resolution spawns a child process (`/usr/bin/env python3 --version`) and synchronously waits
    /// for it to exit, and this property is called from many places (`resolvePython`, `shellCommand`,
    /// `pythonCheck`, etc.) -- making it a computed property that re-resolves each time would make every
    /// call point pay for a process creation and blocking wait for nothing. The venv path does not change
    /// during the process lifetime, so caching is safe.
    static let pythonVenvPath: String = resolveVenvPath()

    private static func resolveVenvPath() -> String {
        let venvDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/utility/mcp-venv")
            .path

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

    // MARK: - Script path resolution (single source of truth)

    /// Resolve path to a script in MCPScripts bundle directory.
    /// Checks bundle first (packaged app), then dev source directory.
    /// Path derivation lives in `MCPScriptsResources` (the prompt template reader shares the same set of candidate directories).
    static func findScript(named name: String) -> String? {
        MCPScriptsResources.path(relative: name)
    }

    // MARK: - Environment variables (single source of truth)

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

        // ai config + language (values share the same source as the `.sh` tasks, see aiEnvironment())
        for (key, value) in aiEnvironment() {
            env[key] = value
        }

        // mcp path config (token_proxy also needs NOTES_DIR, so it lives in the common layer)
        if let notesDir = resolvedNotesDir() {
            env["NOTES_DIR"] = notesDir
        }
        return env
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
        // Language: the Python side picks `prompts/<lang>/` by it. The criterion reuses L10n (single source of truth),
        // otherwise you get combinations no one expects like "Chinese UI, English prompts".
        env[EnvKeys.utilityLang] = L10n.resolvedLanguage(
            configured: ConfigManager.shared.config.general.language,
        )
        return env
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
        var overrides = aiEnvironment()
        overrides["PYTHONDONTWRITEBYTECODE"] = "1" // same as baseEnvironment: do not write .pyc inside the signed bundle
        if let notesDir = resolvedNotesDir() { overrides["NOTES_DIR"] = notesDir }
        overrides["UTILITY_DATA_DIR"] = AppPaths.configDir.path
        overrides["MEMORY_SERVER_URL"] = memoryServerURL
        overrides["SUMMARY_EXCLUDE_TAGS"] = excludeTags
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
        script: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
    ) -> String {
        var parts: [String] = []
        // Sorting keeps the output stable (KEY order does not affect bash semantics)
        for key in environmentOverrides.keys.sorted() {
            parts.append("\(key)=\(environmentOverrides[key] ?? "")")
        }
        parts.append(pythonVenvPath)
        parts.append(script)
        parts.append(contentsOf: arguments)
        return parts.joined(separator: " ")
    }

    // MARK: - One-shot execution (AST batch / single file)

    /// Execute the script with venv python, writing optional stdin and reading/storing stdout as it goes (avoiding the
    /// pipe buffer filling up and blocking the child process); on timeout, kill it and throw.
    /// - Returns: the complete stdout bytes.
    static func runCaptureOutput(
        scriptPath: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval,
    ) throws -> Data {
        guard let pythonPath = resolvePython() else {
            throw PythonProcessError.pythonUnavailable
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath] + arguments

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
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Stop the async read and synchronously drain the rest (the handler may not have read the tail data at the moment of exit)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                throw PythonProcessError.timeout(script: scriptPath)
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
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            "No usable Python (both mcp-venv and system python3 are unavailable)"
        case let .timeout(script):
            "Script \(script) execution timed out"
        case let .launchFailed(msg):
            "Python process failed to launch: \(msg)"
        }
    }
}
