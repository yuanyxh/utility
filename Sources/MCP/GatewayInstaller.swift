import Foundation

/// Installs the bundled `agent-gateway` wheel into the mcp venv.
///
/// A stamp file records the installed wheel name, so relaunches skip pip entirely;
/// dependencies come from the wheel extras, which is the only step needing the network.
/// Offline first launch still gets a working package: the extras install fails, the
/// import error is then visible in the log instead of a mystery "service won't start".
enum GatewayInstaller {
    private static let extras = "proxy,memory,server"
    private static let stampName = ".agent-gateway-wheel"

    /// Ensure the venv holds the wheel; `completion` runs on the main queue.
    static func ensureInstalled(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            install()
            DispatchQueue.main.async(execute: completion)
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
        let wheelName = (wheel as NSString).lastPathComponent

        if !FileManager.default.fileExists(atPath: python) {
            guard run("/usr/bin/env", ["python3", "-m", "venv", venv]) else {
                debugLog("[Gateway] ❌ venv creation failed: \(venv)")
                return
            }
        }
        let installed = (try? String(contentsOfFile: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Size and mtime too: a rebuild reuses the version string, and name-only stamps
        // would silently keep the previous wheel installed.
        let stampValue = fingerprint(of: wheel)
        if installed == stampValue {
            debugLog("[Gateway] \(wheelName) already installed")
            return
        }

        debugLog("[Gateway] Installing \(wheelName)…")
        guard run(python, ["-m", "pip", "install", "--quiet", "--no-deps", "--force-reinstall", wheel]) else {
            debugLog("[Gateway] ❌ wheel install failed")
            return
        }
        guard run(python, ["-m", "pip", "install", "--quiet", "\(wheel)[\(extras)]"]) else {
            debugLog("[Gateway] ⚠️ Dependencies not installed (offline?) — gateway imports may fail")
            return
        }
        try? stampValue.write(toFile: stamp, atomically: true, encoding: .utf8)
        debugLog("[Gateway] Installed \(wheelName)")
    }

    /// `name-size-mtime`, stable across launches but different for a rebuilt wheel.
    private static func fingerprint(of path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\((path as NSString).lastPathComponent)-\(size)-\(Int(mtime))"
    }

    /// Run a command to completion; non-zero exit logs the tail of its output.
    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // Launchd-started GUI apps miss the Homebrew prefix, and `python3` is looked up through PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        task.environment = env
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            debugLog(
                "[Gateway] \(executable) \(arguments.joined(separator: " ")) exited \(task.terminationStatus)\n"
                    + String(output.suffix(800)),
            )
            return false
        }
        return true
    }
}
