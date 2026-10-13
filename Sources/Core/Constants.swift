import Cocoa

// MARK: - App Paths

enum AppPaths {
    /// ~/.config/utility/
    static let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/utility")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/.config/utility/config.yaml
    static let configFile: URL = configDir.appendingPathComponent("config.yaml")

    /// ~/.config/utility/data.sqlite
    static let database: URL = configDir.appendingPathComponent("data.sqlite")

    /// ~/.cache/utility/clip/
    static let clipCacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/utility/clip")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/.cache/utility/stage/
    static let stageCacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/utility/stage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/.cache/utility/debug.log
    static let debugLog: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/utility")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return "\(NSHomeDirectory())/.cache/utility/debug.log"
    }()
}

// MARK: - UserDefaults Keys

enum UDKey {
    static let translationPanelOrigin = "translation_panel_origin"
}

// MARK: - Python Script Names

/// File names of the embedded Python scripts. Referenced across three directories — App/ MCP/ Scanner/ —
/// and constituting the Swift ↔ script-directory contract (the sole argument of `PythonScriptRunner.findScript(named:)`),
/// hence centralized here, to avoid the same file name drifting after literal duplication in many places.
enum PythonScripts {
    static let server = "server.py"
    static let tokenProxy = "token_proxy.py"
    static let summarize = "summarize.py"
    static let astExtractor = "ast_extractor.py"
}

// MARK: - Python Subprocess Environment Variable Names

/// Environment variable names Swift injects into Python scripts (cross-language contract).
///
/// The same name has **two injection points**: `PythonScriptRunner.baseEnvironment()` (the common layer for all scripts)
/// and the inline cmd of `AppDelegate`'s internal tasks (`TaskExecConfig.toProcess()` sets no environment,
/// so the subprocess only inherits the App environment, and tasks must assemble it fully themselves). When literals are scattered, a rename is bound to miss one place,
/// and the symptom of a miss is the Python side reading an empty value and the feature silently degrading (e.g. `config.ai_api_key()` returns "",
/// and summary and embedding grind to a silent halt). Hence all cross-language env vars are registered here; env vars used only inside a single script are not included.
enum EnvKeys {
    /// Generic AI API key. AI text generation and vector embedding share the same key, decoupled from any specific provider,
    /// hence it is not named `DEEPSEEK_API_KEY` — switching providers requires no env var rename.
    static let aiAPIKey = "AI_API_KEY"

    /// Single LLM inference timeout (seconds, from `ai.llmTimeout`).
    /// Applies only to Python-side LLM calls; the agent subprocess timeout goes through `general.aiTimeout` → `AGENT_TIMEOUT`.
    static let aiLLMTimeout = "AI_LLM_TIMEOUT"

    /// UI/prompt language (`zh-Hans` / `en`), from `general.language` (empty = system preference).
    /// The Python side uses this to pick prompts under `prompts/<lang>/` — same source of truth as `L10n.resolvedLanguage`.
    static let utilityLang = "UTILITY_LANG"
}

// MARK: - Shared Pasteboard Types

/// Unified image type set (shared by clipboard + stage drag-in)
enum PasteboardImageTypes {
    static let all: [NSPasteboard.PasteboardType] = [
        .tiff, .png,
        .init("public.jpeg"),
        .init("public.heic"),
        .init("com.compuserve.gif"),
        .init("public.webp"),
        .init("public.bmp"),
    ]
}
