import CryptoKit
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
    static func openHomebrewInstaller(config: AppConfig, log: @escaping (String) -> Void) -> Bool {
        // curl ignores the system proxy; export it for the official installer.
        let proxyURL = systemProxyURL(config: config)
        let script = """
            #!/bin/bash
            set -u
            if [ -n "\(proxyURL?.absoluteString ?? "")" ]; then
              export http_proxy="\(proxyURL?.absoluteString ?? "")" https_proxy="\(proxyURL?.absoluteString ?? "")"
              export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
            fi
            URL="\(homebrewScriptURL)"
            echo "Downloading Homebrew installer: $URL"
            if ! INSTALLER="$(curl -fsSL --max-time 90 "$URL")"; then
              echo ""
              echo "Could not download the installer (GitHub unreachable)."
              echo "Enable a system proxy and retry, or install manually: https://brew.sh"
              read -n 1 -s -r -p "Press any key to close..."
              exit 1
            fi
            if /bin/bash -c "$INSTALLER"; then
              echo "Homebrew installation finished. Return to Utility and click Re-check."
            else
              echo ""
              echo "Homebrew installation did not finish. Check the messages above,"
              echo "then return to Utility and click Re-check. Manual install: https://brew.sh"
            fi
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
            openHomebrewInstaller(config: config, log: log)
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

        if missing.contains(.reranker) {
            guard downloadReranker(config: config, log: log) else {
                return .failure(
                    SetupFailure(step: .reranker, message: "reranker download failed"),
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

    private static let rerankerSHA256 = [
        "tokenizer.json": "48564c5c7d3fa64d85d95e65414a542385f88b0f128fd8d4163fd7a57f2be05c",
        "onnx/model_int8.onnx": "2059d8ef0b6e935b4845e11b38c9af9e9e2e7b91f69fc99efe03254e0a7da8d3",
    ]

    /// First launch has no config.yaml, so `proxyEnabled` is the template default while the
    /// system proxy may exist; use the system proxy until the user has made a choice.
    private static func systemProxyURL(config: AppConfig) -> URL? {
        let firstLaunch = !FileManager.default.fileExists(atPath: AppPaths.configFile.path)
        guard config.general.proxyEnabled || firstLaunch else { return nil }
        return URLSessionManager.readSystemProxy()
    }

    private static func downloadEnvironment(config: AppConfig) -> [String: String] {
        var environment = EnvironmentProbe.probeEnvironment
        guard let proxy = systemProxyURL(config: config) else { return environment }
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            environment[key] = proxy.absoluteString
        }
        return environment
    }

    private static func downloadReranker(
        config: AppConfig,
        log: @escaping (String) -> Void,
    ) -> Bool {
        let directory = SetupProbe.rerankerModelDirectory()
        let onnx = directory.appendingPathComponent("onnx", isDirectory: true)
        try? FileManager.default.createDirectory(at: onnx, withIntermediateDirectories: true)
        let base = "https://huggingface.co/Xenova/bge-reranker-base/resolve/main"
        let files = [
            ("tokenizer.json", directory.appendingPathComponent("tokenizer.json")),
            ("onnx/model_int8.onnx", onnx.appendingPathComponent("model_int8.onnx")),
        ]
        for (remote, target) in files {
            if sha256(of: target) == rerankerSHA256[remote] { continue }
            let temporary = target.appendingPathExtension("download")
            log("[Setup] curl \(base)/\(remote)")
            let arguments = [
                "/usr/bin/curl", "-L", "--fail", "--retry", "2", "--connect-timeout", "20",
                "--speed-limit", "1024", "--speed-time", "60", "-C", "-",
                "-o", temporary.path, "\(base)/\(remote)",
            ]
            let result = ProcessRunner.runSync(
                arguments,
                timeout: 1800,
                environment: downloadEnvironment(config: config),
                onOutput: { log("[Setup] \($0)") },
            )
            guard result.ok else {
                log("[Setup] exit \(result.exitCode)\(result.timedOut ? " (timeout)" : "")")
                debugLog("[Setup] reranker \(remote) failed exit=\(result.exitCode) timeout=\(result.timedOut)")
                return false
            }
            guard sha256(of: temporary) == rerankerSHA256[remote] else {
                log("[Setup] checksum mismatch for \(remote)")
                debugLog("[Setup] reranker \(remote) checksum mismatch")
                try? FileManager.default.trashItem(at: temporary, resultingItemURL: nil)
                return false
            }
            do {
                try? FileManager.default.trashItem(at: target, resultingItemURL: nil)
                try FileManager.default.moveItem(at: temporary, to: target)
            } catch {
                log("[Setup] move failed: \(error.localizedDescription)")
                debugLog("[Setup] reranker move failed \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
        var environment = downloadEnvironment(config: config)
        environment["FASTEMBED_CACHE_PATH"] = cache.path
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // A stalled CDN connection would hang until install times out.
        environment["HF_HUB_DOWNLOAD_TIMEOUT"] = "30"
        let result = ProcessRunner.runSync(
            [python, "-c", code, model, cache.path],
            timeout: 900,
            environment: environment,
            onOutput: { log("[Setup] \($0)") },
        )
        log("[Setup] exit \(result.exitCode)\(result.timedOut ? " (timeout)" : "")")
        if !result.ok {
            debugLog("[Setup] embedder download failed exit=\(result.exitCode) timeout=\(result.timedOut)")
        }
        return result
    }
}
