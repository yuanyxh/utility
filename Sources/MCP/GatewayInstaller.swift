import Foundation

/// Installs the bundled `agent-gateway` wheel into the mcp venv.
///
/// A stamp file records the installed wheel fingerprint, so relaunches skip pip entirely.
/// Every step is bounded by a timeout: the whole Python layer starts only after this returns,
/// so a stalled pip would otherwise leave the app with no MCP, no proxy and no knowledge panel.
///
/// Success is only declared after the extras are importable. `pip` treats an unknown extra as
/// a warning and still exits 0, so a renamed extra would otherwise install base deps only,
/// look successful, and break every service at import time.
enum GatewayInstaller {
    private static let extras = "proxy,memory,server"
    /// Top-level imports that only exist when the extras installed cleanly.
    private static let extrasImports = ["aiohttp", "uvicorn", "mcp", "mem0", "fastembed", "qdrant_client"]
    private static let stampName = ".agent-gateway-wheel"
    private static let brokenMarker = ".agent-gateway-broken"

    private enum Timeout {
        static let venv: TimeInterval = 120
        static let wheel: TimeInterval = 180
        static let dependencies: TimeInterval = 900
        static let imports: TimeInterval = 60
    }

    /// Ensure the venv holds the wheel; `completion` runs on the main queue.
    static func ensureInstalled(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            install()
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// True when a previous attempt failed and nothing has fixed it since.
    static var isKnownBroken: Bool {
        FileManager.default.fileExists(atPath: "\(PythonScriptRunner.venvDir)/\(brokenMarker)")
    }

    /// `agent_gateway` is importable from the venv (a bare venv is not enough: the install
    /// may have failed offline, and registering tasks against it fails every run).
    static var isInstalled: Bool {
        guard !isKnownBroken else { return false }
        let lib = PythonScriptRunner.venvDir + "/lib"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: lib) else {
            return false
        }
        return versions.contains {
            FileManager.default.fileExists(atPath: "\(lib)/\($0)/site-packages/agent_gateway")
        }
    }

    private static func install() {
        guard let wheel = GatewayResources.bundledWheel() else {
            debugLog("[Gateway] No bundled wheel, falling back to PYTHONPATH sources")
            return
        }
        let venv = PythonScriptRunner.venvDir
        let python = PythonScriptRunner.pythonVenvPath
        let stamp = "\(venv)/\(stampName)"
        let broken = "\(venv)/\(brokenMarker)"
        let wheelName = (wheel as NSString).lastPathComponent

        if !FileManager.default.fileExists(atPath: python),
           !run(["/usr/bin/env", "python3", "-m", "venv", venv], timeout: Timeout.venv).ok
        {
            debugLog("[Gateway] ❌ venv creation failed: \(venv)")
            markBroken(broken)
            return
        }

        // Size and mtime too: a rebuild reuses the version string, and a name-only stamp
        // would silently keep the previous wheel installed.
        let stampValue = fingerprint(of: wheel)
        let installed = (try? String(contentsOfFile: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if installed == stampValue, isInstalled {
            try? FileManager.default.removeItem(atPath: broken)
            debugLog("[Gateway] \(wheelName) already installed")
            return
        }

        debugLog("[Gateway] Installing \(wheelName)…")
        guard run(
            [python, "-m", "pip", "install", "--quiet", "--no-deps", "--force-reinstall", wheel],
            timeout: Timeout.wheel,
        ).ok else {
            debugLog("[Gateway] ❌ wheel install failed")
            markBroken(broken)
            return
        }

        guard installDependencies(python: python, wheel: wheel) else {
            markBroken(broken)
            return
        }
        guard run(
            [python, "-c", "import " + extrasImports.joined(separator: ", ")],
            timeout: Timeout.imports,
        ).ok else {
            debugLog("[Gateway] ❌ extras installed but not importable")
            markBroken(broken)
            return
        }

        try? stampValue.write(toFile: stamp, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: broken)
        debugLog("[Gateway] Installed \(wheelName)")
    }

    /// Dependencies from the wheel extras: a packaging-time constraints snapshot first,
    /// plain resolution as fallback so a stale pin never blocks the app.
    private static func installDependencies(python: String, wheel: String) -> Bool {
        let requirement = "\(wheel)[\(extras)]"
        var output = ""
        if let constraints = GatewayResources.constraintsFile() {
            let constrained = run(
                [python, "-m", "pip", "install", "--quiet", "-c", constraints, requirement],
                timeout: Timeout.dependencies,
            )
            if constrained.ok {
                output = constrained.output
            } else {
                debugLog("[Gateway] ⚠️ Constrained install failed, retrying without constraints")
                let retry = run(
                    [python, "-m", "pip", "install", "--quiet", requirement],
                    timeout: Timeout.dependencies,
                )
                output = constrained.output + retry.output
                if !retry.ok {
                    debugLog("[Gateway] ⚠️ Dependencies not installed (offline?) — gateway imports may fail")
                    return false
                }
            }
        } else {
            let result = run(
                [python, "-m", "pip", "install", "--quiet", requirement],
                timeout: Timeout.dependencies,
            )
            output = result.output
            if !result.ok {
                debugLog("[Gateway] ⚠️ Dependencies not installed (offline?) — gateway imports may fail")
                return false
            }
        }
        // pip reports an unknown extra as a warning and exits 0: only the text reveals it
        if output.lowercased().contains("does not provide the extra") {
            debugLog("[Gateway] ❌ pip skipped an unknown extra (the extras list drifted)")
            return false
        }
        return true
    }

    private static func markBroken(_ path: String) {
        try? Data().write(to: URL(fileURLWithPath: path))
    }

    /// `name-size-mtime`, stable across launches but different for a rebuilt wheel.
    private static func fingerprint(of path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\((path as NSString).lastPathComponent)-\(size)-\(Int(mtime))"
    }

    /// Run a command to completion; non-zero exit or timeout logs the tail of its output.
    private static func run(_ arguments: [String], timeout: TimeInterval) -> (ok: Bool, output: String) {
        guard let executable = arguments.first else { return (false, "") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // Launchd-started GUI apps miss the Homebrew prefix, and `python3` is looked up through PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        task.environment = env

        var output = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            output.append(chunk)
            lock.unlock()
        }
        guard (try? task.run()) != nil else {
            return (false, "failed to launch \(executable)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let timedOut = task.isRunning
        if timedOut {
            kill(task.processIdentifier, SIGKILL)
            task.waitUntilExit()
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        lock.unlock()

        let text = String(data: output, encoding: .utf8) ?? ""
        guard !timedOut, task.terminationStatus == 0 else {
            debugLog(
                "[Gateway] \(arguments.joined(separator: " ")) "
                    + (timedOut ? "timed out after \(Int(timeout))s" : "exited \(task.terminationStatus)")
                    + "\n" + String(text.suffix(800)),
            )
            return (false, text)
        }
        return (true, text)
    }
}
