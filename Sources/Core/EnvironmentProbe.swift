import Foundation

struct PythonResolution: Sendable, Equatable {
    var path: String
    var version: String
    var major: Int
    var minor: Int
}

/// Locates host tools without relying on the GUI process PATH.
enum EnvironmentProbe {
    /// Homebrew prefixes first: a launchd-started app does not inherit the shell PATH.
    static var probeEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (prefixes + inherited).joined(separator: ":")
        return environment
    }

    static func resolvePython(atLeast minimum: (Int, Int)) -> PythonResolution? {
        for path in pythonCandidates() {
            guard let version = version(of: path) else { continue }
            let parsed = parse(version)
            guard parsed.0 > 0, isAtLeast(parsed.0, parsed.1, minimum) else { continue }
            return PythonResolution(path: path, version: version, major: parsed.0, minor: parsed.1)
        }
        return nil
    }

    static func version(of executable: String, arguments: [String] = ["--version"]) -> String? {
        let result = CommandRunner.run(
            [executable] + arguments,
            timeout: 5,
            environment: probeEnvironment,
        )
        guard result.ok else { return nil }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"\d+\.\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    static func homebrewPath() -> String? {
        firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) ?? which("brew")
    }

    static func tmuxPath() -> String? {
        firstExisting(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]) ?? which("tmux")
    }

    static func xcodeCLTPath() -> String? {
        let result = CommandRunner.run(
            ["/usr/bin/xcode-select", "-p"],
            timeout: 5,
            environment: probeEnvironment,
        )
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    /// `pyvenv.cfg` is the authority: an interpreter existing does not mean the venv was
    /// created with a supported Python.
    static func venvVersion(at venv: String) -> String? {
        let config = URL(fileURLWithPath: venv).appendingPathComponent("pyvenv.cfg")
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                guard key == "version" || key == "version_info" else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if let range = value.range(
                    of: #"\d+\.\d+(?:\.\d+)?"#,
                    options: .regularExpression,
                ) {
                    return String(value[range])
                }
            }
        }
        return version(of: URL(fileURLWithPath: venv).appendingPathComponent("bin/python3").path)
    }

    static func venvNeedsRebuild(at venv: String, minimum: (Int, Int) = (3, 12)) -> Bool {
        guard let raw = venvVersion(at: venv) else { return true }
        let parsed = parse(raw)
        return !isAtLeast(parsed.0, parsed.1, minimum)
    }

    static func isAtLeast(_ major: Int, _ minor: Int, _ minimum: (Int, Int)) -> Bool {
        major > minimum.0 || (major == minimum.0 && minor >= minimum.1)
    }

    private static func pythonCandidates() -> [String] {
        var paths = ["python3.14", "python3.13", "python3.12"].flatMap { name in
            ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        }
        if let python3 = which("python3") {
            paths.append(python3)
        }
        paths.append("/usr/bin/python3")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func parse(_ version: String) -> (Int, Int) {
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func which(_ name: String) -> String? {
        let result = CommandRunner.run(
            ["/usr/bin/which", name],
            timeout: 3,
            environment: probeEnvironment,
        )
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, !path.isEmpty else { return nil }
        return path
    }
}
