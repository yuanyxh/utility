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

// MARK: - Python 脚本名

/// 内嵌 Python 脚本的文件名。跨 App/ MCP/ Scanner/ 三个目录引用，
/// 且是 Swift ↔ 脚本目录的约定（`PythonScriptRunner.findScript(named:)` 的唯一入参），
/// 故集中此处，避免同一文件名在多处字面量重复后漂移。
enum PythonScripts {
    static let server = "server.py"
    static let tokenProxy = "token_proxy.py"
    static let summarize = "summarize.py"
    static let astExtractor = "ast_extractor.py"
}

// MARK: - Python 子进程环境变量名

/// Swift 注入给 Python 脚本的环境变量名（跨语言契约）。
///
/// 同一个名字存在**两个注入点**：`PythonScriptRunner.baseEnvironment()`（所有脚本的公共层）
/// 与 `AppDelegate` 的内部任务内联 cmd（`TaskExecConfig.toProcess()` 不设环境，
/// 子进程只继承 App 环境，故任务需自己拼全）。分散写字面量时改名必然漏掉一处，
/// 而漏掉的表现是 Python 侧读到空值、功能静默降级（如 `config.ai_api_key()` 返回 ""，
/// 总结与嵌入无声停摆）。故跨语言 env 一律登记于此；仅单一脚本内部使用的 env 不入此列。
enum EnvKeys {
    /// 通用 AI API key。AI 文本生成与向量嵌入共用同一个 key，与具体 provider 解绑，
    /// 故不叫 `DEEPSEEK_API_KEY`——换 provider 不需要改环境变量名。
    static let aiAPIKey = "AI_API_KEY"

    /// LLM 单次推理超时（秒，来自 `ai.llmTimeout`）。
    /// 只作用于 Python 侧的 LLM 调用；agent 子进程超时走 `general.aiTimeout` → `AGENT_TIMEOUT`。
    static let aiLLMTimeout = "AI_LLM_TIMEOUT"

    /// 界面/提示词语言（`zh-Hans` / `en`），来自 `general.language`（空则系统首选）。
    /// Python 侧据此选择 `prompts/<lang>/` 下的提示词——判据与 `L10n.resolvedLanguage` 同源。
    static let utilityLang = "UTILITY_LANG"
}

// MARK: - Shared Pasteboard Types

/// 图片类型统一集合（剪切板 + 暂存拖入共用）
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
