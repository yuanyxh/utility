import Foundation

enum SetupItemID: String, CaseIterable, Sendable {
    case xcodeCLT
    case homebrew
    case python
    case tmux
    case gateway
    case embedder
    case reranker
}

enum SetupState: Equatable, Sendable {
    case ok
    case missing
    case optional
    case failed(String)
}

struct SetupItem: Identifiable, Equatable, Sendable {
    var id: SetupItemID
    var state: SetupState
    var version: String?
    var path: String?
    var detail: String?
    var isRequired: Bool
}

/// Checks the tools the Python layer and the terminal need before first launch.
enum SetupProbe {
    static let minimumPython = (3, 12)

    static func check(config: AppConfig, configDir _: URL) -> [SetupItem] {
        [
            xcodeItem(),
            homebrewItem(),
            pythonItem(),
            tmuxItem(config: config),
            gatewayItem(),
            embedderItem(config: config),
            rerankerItem(config: config),
        ]
    }

    static func rerankerModelDirectory() -> URL {
        AppPaths.rerankerModelDir
    }

    private static func rerankerItem(config: AppConfig) -> SetupItem {
        let required = config.mcp?.enabled == true
        let directory = rerankerModelDirectory()
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        let model = directory.appendingPathComponent("onnx/model_int8.onnx")
        if FileManager.default.fileExists(atPath: tokenizer.path),
            FileManager.default.fileExists(atPath: model.path)
        {
            return SetupItem(
                id: .reranker,
                state: .ok,
                version: "bge-reranker-base-int8",
                path: directory.path,
                isRequired: false,
            )
        }
        return SetupItem(
            id: .reranker,
            state: required ? .missing : .optional,
            version: "bge-reranker-base-int8",
            path: directory.path,
            detail: required
                ? L10n.Setup.rerankerDownloadHint
                : L10n.Setup.mcpDisabledHint,
            isRequired: false,
        )
    }

    static func embedderCacheDirectory(config: AppConfig) -> URL {
        let raw = (config.mcp?.fastembedCacheDir ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/utility/fastembed", isDirectory: true)
    }

    static func embedderModelName(config: AppConfig) -> String {
        let raw = (config.mcp?.embedderModel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "sentence-transformers/all-MiniLM-L6-v2" : raw
    }

    static func embedderModelDirectory(config: AppConfig) -> URL {
        let folder = embedderModelName(config: config).replacingOccurrences(of: "/", with: "--")
        return embedderCacheDirectory(config: config)
            .appendingPathComponent("models--\(folder)", isDirectory: true)
    }

    private static func xcodeItem() -> SetupItem {
        if let path = EnvironmentProbe.xcodeCLTPath() {
            return SetupItem(
                id: .xcodeCLT,
                state: .ok,
                version: nil,
                path: path,
                detail: nil,
                isRequired: true,
            )
        }
        return SetupItem(
            id: .xcodeCLT,
            state: .optional,
            detail: "The Homebrew installer also installs the command line tools",
            isRequired: false,
        )
    }

    private static func homebrewItem() -> SetupItem {
        if let path = EnvironmentProbe.homebrewPath() {
            return SetupItem(
                id: .homebrew,
                state: .ok,
                version: EnvironmentProbe.version(of: path),
                path: path,
                isRequired: true,
            )
        }
        return SetupItem(id: .homebrew, state: .missing, isRequired: true)
    }

    private static func pythonItem() -> SetupItem {
        if let resolution = EnvironmentProbe.resolvePython(atLeast: minimumPython) {
            return SetupItem(
                id: .python,
                state: .ok,
                version: resolution.version,
                path: resolution.path,
                isRequired: true,
            )
        }
        return SetupItem(id: .python, state: .missing, isRequired: true)
    }

    private static func tmuxItem(config: AppConfig) -> SetupItem {
        let required = config.terminal.enabled
        if let path = EnvironmentProbe.tmuxPath() {
            return SetupItem(
                id: .tmux,
                state: .ok,
                version: EnvironmentProbe.version(of: path, arguments: ["-V"]),
                path: path,
                isRequired: required,
            )
        }
        return SetupItem(
            id: .tmux,
            state: required ? .missing : .optional,
            detail: required ? nil : "The terminal is disabled in Settings",
            isRequired: required,
        )
    }

    private static func gatewayItem() -> SetupItem {
        let wheel = GatewayResources.bundledWheel()
        let name = wheel.map { ($0 as NSString).lastPathComponent }
        if GatewayInstaller.isInstalled {
            return SetupItem(
                id: .gateway,
                state: .ok,
                version: name,
                path: PythonScriptRunner.venvDir,
                isRequired: true,
            )
        }
        return SetupItem(
            id: .gateway,
            state: .missing,
            version: name,
            path: PythonScriptRunner.venvDir,
            isRequired: true,
        )
    }

    private static func embedderItem(config: AppConfig) -> SetupItem {
        let required = config.mcp?.enabled == true
        let directory = embedderModelDirectory(config: config)
        if FileManager.default.fileExists(atPath: directory.path) {
            return SetupItem(
                id: .embedder,
                state: .ok,
                version: embedderModelName(config: config),
                path: directory.path,
                isRequired: required,
            )
        }
        return SetupItem(
            id: .embedder,
            state: required ? .missing : .optional,
            version: embedderModelName(config: config),
            path: directory.path,
            detail: required ? "Downloaded on first use" : "MCP is disabled in Settings",
            isRequired: required,
        )
    }
}
