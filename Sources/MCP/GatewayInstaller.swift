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
    private static let minimumPython = (3, 12)

    private enum Timeout {
        static let venv: TimeInterval = 120
        static let wheel: TimeInterval = 180
        static let dependencies: TimeInterval = 900
        static let imports: TimeInterval = 60
    }

    /// Ensure the venv holds the wheel; `completion` runs on the main queue.
    static func ensureInstalled(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            install(progress: { debugLog($0) })
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// True when a previous attempt failed and nothing has fixed it since.
    static var isKnownBroken: Bool {
        FileManager.default.fileExists(atPath: "\(PythonScriptRunner.venvDir)/\(brokenMarker)")
    }

    static var bundledWheelName: String? {
        GatewayResources.bundledWheel().map { ($0 as NSString).lastPathComponent }
    }

    /// Forces the next install pass to verify the wheel again (used after importing data).
    static func invalidateStamp() {
        let url = URL(fileURLWithPath: "\(PythonScriptRunner.venvDir)/\(stampName)")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
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

    @discardableResult
    static func install(progress: @escaping (String) -> Void) -> Bool {
        guard let wheel = GatewayResources.bundledWheel() else {
            progress("[Gateway] No bundled wheel, falling back to PYTHONPATH sources")
            return false
        }
        let venv = PythonScriptRunner.venvDir
        let stamp = "\(venv)/\(stampName)"
        let broken = "\(venv)/\(brokenMarker)"
        let wheelName = (wheel as NSString).lastPathComponent

        if FileManager.default.fileExists(atPath: venv),
            EnvironmentProbe.venvNeedsRebuild(at: venv, minimum: minimumPython)
        {
            let version = EnvironmentProbe.venvVersion(at: venv) ?? "unknown"
            progress("[Gateway] venv Python \(version) is below 3.12; rebuilding")
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: venv),
                    resultingItemURL: nil,
                )
            } catch {
                progress("[Gateway] ❌ cannot move the stale venv to the Trash")
                markBroken(broken)
                return false
            }
        }

        if FileManager.default.fileExists(atPath: venv),
            !FileManager.default.fileExists(atPath: PythonScriptRunner.pythonVenvPath)
        {
            progress("[Gateway] venv has no interpreter; rebuilding")
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: venv),
                    resultingItemURL: nil,
                )
            } catch {
                progress("[Gateway] ❌ cannot move the broken venv to the Trash")
                markBroken(broken)
                return false
            }
        }

        var python = PythonScriptRunner.pythonVenvPath
        if !FileManager.default.fileExists(atPath: python) {
            guard let resolution = EnvironmentProbe.resolvePython(atLeast: minimumPython) else {
                let hint = "brew install python@3.12"
                progress("[Gateway] ❌ Python 3.12+ not found. Install it with: \(hint)")
                markBroken(broken)
                return false
            }
            progress("[Gateway] interpreter: \(resolution.path) (\(resolution.version))")
            let created = run(
                [resolution.path, "-m", "venv", venv],
                timeout: Timeout.venv,
                progress: progress,
            )
            guard created.ok else {
                progress("[Gateway] ❌ venv creation failed: \(venv)")
                markBroken(broken)
                return false
            }
            python = "\(venv)/bin/python3"
            if !FileManager.default.fileExists(atPath: python) {
                progress("[Gateway] ❌ venv interpreter missing after creation: \(python)")
                markBroken(broken)
                return false
            }
        }

        // Size and mtime too: a rebuild reuses the version string, and a name-only stamp
        // would silently keep the previous wheel installed.
        let stampValue = fingerprint(of: wheel)
        let installed = (try? String(contentsOfFile: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if installed == stampValue, isInstalled {
            try? FileManager.default.removeItem(atPath: broken)
            progress("[Gateway] \(wheelName) already installed")
            return true
        }

        progress("[Gateway] Installing \(wheelName)…")
        let wheelResult = run(
            [python, "-m", "pip", "install", "--quiet", "--no-deps", "--force-reinstall", wheel],
            timeout: Timeout.wheel,
            progress: progress,
        )
        guard wheelResult.ok else {
            progress("[Gateway] ❌ wheel install failed")
            markBroken(broken)
            return false
        }

        guard installDependencies(python: python, wheel: wheel, progress: progress) else {
            markBroken(broken)
            return false
        }
        let imports = run(
            [python, "-c", "import " + extrasImports.joined(separator: ", ")],
            timeout: Timeout.imports,
            progress: progress,
        )
        guard imports.ok else {
            progress("[Gateway] ❌ extras installed but not importable")
            markBroken(broken)
            return false
        }

        try? stampValue.write(toFile: stamp, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: broken)
        progress("[Gateway] Installed \(wheelName)")
        return true
    }

    /// Dependencies from the wheel extras: a packaging-time constraints snapshot first,
    /// plain resolution as fallback so a stale pin never blocks the app.
    private static func installDependencies(
        python: String,
        wheel: String,
        progress: @escaping (String) -> Void,
    ) -> Bool {
        let requirement = "\(wheel)[\(extras)]"
        var output = ""
        if let constraints = GatewayResources.constraintsFile() {
            let constrained = run(
                [python, "-m", "pip", "install", "--quiet", "-c", constraints, requirement],
                timeout: Timeout.dependencies,
                progress: progress,
            )
            if constrained.ok {
                output = constrained.output
            } else {
                progress("[Gateway] ⚠️ Constrained install failed, retrying without constraints")
                let retry = run(
                    [python, "-m", "pip", "install", "--quiet", requirement],
                    timeout: Timeout.dependencies,
                    progress: progress,
                )
                output = constrained.output + retry.output
                if !retry.ok {
                    progress("[Gateway] ⚠️ Dependencies not installed (offline?) — gateway imports may fail")
                    return false
                }
            }
        } else {
            let result = run(
                [python, "-m", "pip", "install", "--quiet", requirement],
                timeout: Timeout.dependencies,
                progress: progress,
            )
            output = result.output
            if !result.ok {
                progress("[Gateway] ⚠️ Dependencies not installed (offline?) — gateway imports may fail")
                return false
            }
        }
        // pip reports an unknown extra as a warning and exits 0: only the text reveals it
        if output.lowercased().contains("does not provide the extra") {
            progress("[Gateway] ❌ pip skipped an unknown extra (the extras list drifted)")
            return false
        }
        return true
    }

    private static func run(
        _ arguments: [String],
        timeout: TimeInterval,
        progress: @escaping (String) -> Void,
    ) -> ProcessResult {
        let result = ProcessRunner.runSync(
            arguments,
            timeout: timeout,
            environment: EnvironmentProbe.probeEnvironment,
        )
        guard !result.ok else { return result }
        let reason = result.timedOut ? "timed out after \(Int(timeout))s" : "exited \(result.exitCode)"
        progress(
            "[Gateway] ❌ \(arguments.joined(separator: " ")) \(reason)\n"
                + String(result.output.suffix(800)),
        )
        return result
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
}
