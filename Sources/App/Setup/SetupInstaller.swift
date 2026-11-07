import Foundation

struct SetupFailure: LocalizedError {
    var step: SetupItemID
    var message: String

    var errorDescription: String? {
        "\(step.rawValue): \(message)"
    }
}

/// Runs the confirmed install steps on a background queue and streams their output.
enum SetupInstaller {
    static let homebrewScriptURL =
        "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

    static func install(
        items: [SetupItem],
        config: AppConfig,
        venvPython: String?,
        log: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void,
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(
                missing: Set(items.filter { $0.state == .missing }.map(\.id)),
                config: config,
                venvPython: venvPython,
                log: log,
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Writes the fixed official script to a `.command` file and lets Terminal run it.
    @discardableResult
    static func openHomebrewInstaller(log: @escaping (String) -> Void) -> Bool {
        let script = """
            #!/bin/bash
            set -e
            /bin/bash -c "$(curl -fsSL \(homebrewScriptURL))"
            echo "Homebrew installation finished. Return to Utility and click Re-check."
            read -n 1 -s -r -p "Press any key to close..."
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("utility-install-homebrew.command")
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path,
            )
            let result = ProcessRunner.runSync(
                ["/usr/bin/open", url.path],
                timeout: 10,
                environment: EnvironmentProbe.probeEnvironment,
            )
            guard result.ok else {
                throw SetupFailure(step: .homebrew, message: "cannot open Terminal")
            }
            log("[Setup] opening Terminal for \(homebrewScriptURL)")
            return true
        } catch {
            log("[Setup] ❌ \(error.localizedDescription)")
            return false
        }
    }

    private static func run(
        missing: Set<SetupItemID>,
        config: AppConfig,
        venvPython: String?,
        log: @escaping (String) -> Void,
    ) -> Result<Void, Error> {
        if missing.contains(.homebrew) {
            openHomebrewInstaller(log: log)
            return .success(())
        }

        if missing.contains(.python), let brew = EnvironmentProbe.homebrewPath() {
            guard brewInstall("python@3.12", brew: brew, timeout: 900, log: log) else {
                return .failure(SetupFailure(step: .python, message: "brew install failed"))
            }
        }

        if missing.contains(.tmux), config.terminal.enabled,
            let brew = EnvironmentProbe.homebrewPath()
        {
            guard brewInstall("tmux", brew: brew, timeout: 600, log: log) else {
                return .failure(SetupFailure(step: .tmux, message: "brew install failed"))
            }
        }

        if missing.contains(.gateway) {
            guard GatewayInstaller.install(progress: log) else {
                return .failure(
                    SetupFailure(step: .gateway, message: "wheel install failed"),
                )
            }
        }

        if missing.contains(.embedder) {
            guard let python = resolvedVenvPython(venvPython) else {
                return .failure(
                    SetupFailure(step: .embedder, message: "venv Python is unavailable"),
                )
            }
            let result = downloadEmbedder(python: python, config: config, log: log)
            guard result.ok else {
                return .failure(
                    SetupFailure(step: .embedder, message: "model download failed"),
                )
            }
        }

        return .success(())
    }

    private static func brewInstall(
        _ formula: String,
        brew: String,
        timeout: TimeInterval,
        log: @escaping (String) -> Void,
    ) -> Bool {
        log("[Setup] \(brew) install \(formula)")
        var environment = EnvironmentProbe.probeEnvironment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let result = ProcessRunner.runSync(
            [brew, "install", formula],
            timeout: timeout,
            environment: environment,
            onOutput: { log("[Setup] \($0)") },
        )
        log("[Setup] exit \(result.exitCode)\(result.timedOut ? " (timeout)" : "")")
        return result.ok
    }

    private static func resolvedVenvPython(_ preferred: String?) -> String? {
        let candidates = [preferred, PythonScriptRunner.pythonVenvPath].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func downloadEmbedder(
        python: String,
        config: AppConfig,
        log: @escaping (String) -> Void,
    ) -> ProcessResult {
        let cache = SetupProbe.embedderCacheDirectory(config: config)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let model = SetupProbe.embedderModelName(config: config)
        let code = """
            import sys
            from fastembed import TextEmbedding
            TextEmbedding(model_name=sys.argv[1], cache_dir=sys.argv[2])
            print("model-ready")
            """
        log("[Setup] \(python) -c <download embedder \(model)>")
        var environment = EnvironmentProbe.probeEnvironment
        environment["FASTEMBED_CACHE_PATH"] = cache.path
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        let result = ProcessRunner.runSync(
            [python, "-c", code, model, cache.path],
            timeout: 1800,
            environment: environment,
            onOutput: { log("[Setup] \($0)") },
        )
        log("[Setup] exit \(result.exitCode)\(result.timedOut ? " (timeout)" : "")")
        return result
    }
}
