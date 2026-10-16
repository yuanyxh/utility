import Foundation

/// Lightweight i18n — JSON dictionary approach
/// Defaults to Chinese (zh-Hans), supports English (en)
/// Language changes are broadcast via NotificationCenter as L10n.languageDidChange
enum L10n {
    static let languageDidChange = Notification.Name("L10n.languageDidChange")

    private static var dict: [String: String] = [:]
    static var currentLanguage: String {
        _lang
    }

    private static var _lang = "zh-Hans"

    /// Auto-load on first access to any string (system preferred language)
    private static let _ready: Bool = {
        loadJSON(language: resolvedLanguage(), notify: false)
        return true
    }()

    /// Called after ConfigManager.load() — overrides the language per config file
    static func setup() {
        loadJSON(
            language: resolvedLanguage(
                configured: ConfigManager.shared.config.general.language,
            ),
            notify: true,
        )
    }

    // MARK: - Language Resolution (Single Source)

    /// Language normalization: `zh*` → `zh-Hans`, everything else → `en`.
    static func normalize(_ language: String) -> String {
        language.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    /// Currently effective language: config takes priority; empty follows the system preference.
    ///
    /// This is the **single cross-language source of truth** — L10n itself, and the `UTILITY_LANG` injected into Python
    /// (which decides which prompt set `prompts/<lang>/` selects) both go through here. Deriving it in two places will sooner or later produce
    /// a combination nobody expects, such as "Chinese UI, English prompts".
    /// The default parameter does not read `ConfigManager`: `_ready` may fire before config load, and reading config then would crash.
    static func resolvedLanguage(configured: String = "") -> String {
        normalize(configured.isEmpty ? preferredLanguage() : configured)
    }

    private static func loadJSON(language: String, notify: Bool) {
        let lang = language.hasPrefix("zh") ? "zh-Hans" : "en"
        _lang = lang
        guard let url = Bundle.module.url(forResource: lang, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            if lang != "zh-Hans",
               let fbURL = Bundle.module.url(forResource: "zh-Hans", withExtension: "json"),
               let fbData = try? Data(contentsOf: fbURL),
               let fbJSON = try? JSONSerialization.jsonObject(with: fbData) as? [String: String]
            {
                _lang = "zh-Hans"
                dict = fbJSON
            } else {
                dict = [:]
            }
            if notify {
                NotificationCenter.default.post(name: languageDidChange, object: nil)
            }
            return
        }
        dict = json
        if notify {
            NotificationCenter.default.post(name: languageDidChange, object: nil)
        }
    }

    // MARK: - Key lookup

    static func string(_ key: String) -> String {
        _ = _ready
        return dict[key] ?? key
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        _ = _ready
        return String(format: dict[key] ?? key, arguments: args)
    }

    private static func preferredLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
        return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
    }
}

// MARK: - Menu Strings

extension L10n {
    enum Menu {
        static var reloadConfig: String {
            string("menu.reload_config")
        }

        static var launchAtLogin: String {
            string("menu.launch_at_login")
        }

        static var rss: String {
            string("menu.rss")
        }

        static var tasks: String {
            string("menu.tasks")
        }

        static var clearClipboard: String {
            string("menu.clear_clipboard")
        }

        static var quit: String {
            string("menu.quit")
        }

        static var rssFetch: String {
            string("menu.rss_fetch")
        }

        static var rssMarkAllRead: String {
            string("menu.rss_mark_all_read")
        }

        static func rssUnread(_ n: Int) -> String {
            format("menu.rss_unread", n)
        }

        static func tasksCount(_ n: Int) -> String {
            format("menu.tasks_count", n)
        }

        static var rssFetchFailed: String {
            string("notify.rss_fetch_failed")
        }

        static func taskFailed(_ name: String) -> String {
            format("notify.task_failed", name)
        }

        static func taskCompleted(_ name: String) -> String {
            format("notify.task_completed", name)
        }

        static var launchAtLoginFailed: String {
            string("notify.launch_at_login_failed")
        }

        static var configReloadFailed: String {
            string("notify.config_reload_failed")
        }

        static var configLoadFailed: String {
            string("notify.config_load_failed")
        }

        static var dbInitFailed: String {
            string("notify.db_init_failed")
        }

        static var hotkeyParseFailed: String {
            string("notify.hotkey_parse_failed")
        }

        static var hotkeyRegisterFailed: String {
            string("notify.hotkey_register_failed")
        }
    }
}

// MARK: - Clipboard Strings

extension L10n {
    enum Clipboard {
        static var unreadable: String {
            string("clipboard.unreadable")
        }

        static var file: String {
            string("clipboard.file")
        }

        static func fileCount(_ n: Int) -> String {
            format("clipboard.file_count", n)
        }

        static var webContent: String {
            string("clipboard.web_content")
        }

        static var unknown: String {
            string("clipboard.unknown")
        }
    }
}

// MARK: - Translation Strings

extension L10n {
    enum Translation {
        static var source: String {
            string("translation.source")
        }

        static var target: String {
            string("translation.target")
        }

        static var noApiKey: String {
            string("translation.no_api_key")
        }

        static var missingApiKey: String {
            string("error.missing_api_key")
        }

        static var apiFailed: String {
            string("error.api_failed")
        }

        static var invalidURL: String {
            string("error.invalid_url")
        }

        static var invalidResponse: String {
            string("error.invalid_response")
        }

        static var emptyResponse: String {
            string("error.empty_response")
        }

        static func encodeFailed(_ msg: String) -> String {
            format("error.encode_failed", msg)
        }

        static func parseFailed(_ msg: String) -> String {
            format("error.parse_failed", msg)
        }
    }
}

// MARK: - Knowledge Strings

extension L10n {
    enum Knowledge {
        static var title: String {
            string("knowledge.title")
        }

        static var tabTopic: String {
            string("knowledge.tab_topic")
        }

        static var tabFragment: String {
            string("knowledge.tab_fragment")
        }

        static var empty: String {
            string("knowledge.empty")
        }

        static var known: String {
            string("knowledge.known")
        }

        static var dislike: String {
            string("knowledge.dislike")
        }

        static var like: String {
            string("knowledge.like")
        }

        static var promote: String {
            string("knowledge.promote")
        }

        static var copy: String {
            string("knowledge.copy")
        }

        static var copied: String {
            string("knowledge.copied")
        }

        static var close: String {
            string("knowledge.close")
        }

        static var sources: String {
            string("knowledge.sources")
        }

        static var kindPrinciple: String {
            string("knowledge.kind_principle")
        }

        static var kindTrend: String {
            string("knowledge.kind_trend")
        }

        static var taskRefill: String {
            string("knowledge.task_refill")
        }

        static var menuShow: String {
            string("menu.knowledge_show")
        }

        static var menuRefill: String {
            string("menu.knowledge_refill")
        }
    }
}

// MARK: - Stage Strings

extension L10n {
    enum Stage {
        static var clear: String {
            string("stage.clear")
        }

        static var file: String {
            string("stage.file")
        }

        static func fileCount(_ n: Int) -> String {
            format("stage.file_count", n)
        }

        static var unknown: String {
            string("stage.unknown")
        }
    }
}

// MARK: - Config Strings

extension L10n {
    enum Config {
        static var headerComment: String {
            string("config.header_comment")
        }
    }
}

// MARK: - Prompt Strings

extension L10n {
    enum Prompt {
        static var translate: String {
            string("prompt.translate")
        }

        static var translateAuto: String {
            string("prompt.translate_auto")
        }
    }
}

// MARK: - RSS Strings

extension L10n {
    enum RSS {
        static var helpHeader: String {
            string("rss.help_header")
        }

        static var helpFetch: String {
            string("rss.help_fetch")
        }

        static var helpList: String {
            string("rss.help_list")
        }

        static var helpMarkRead: String {
            string("rss.help_mark_read")
        }

        static var helpMarkAllRead: String {
            string("rss.help_mark_all_read")
        }

        static func fetchDone(_ n: Int) -> String {
            format("rss.fetch_done", n)
        }

        static func markReadDone(_ id: String) -> String {
            format("rss.mark_read_done", id)
        }

        static var markAllReadDone: String {
            string("rss.mark_all_read_done")
        }
    }
}

// MARK: - MCP Strings

extension L10n {
    enum MCP {
        static var restartService: String {
            string("menu.mcp_restart")
        }

        static var disabled: String {
            string("menu.mcp_disabled")
        }

        static func qdrantPath(_ path: String) -> String {
            format("menu.mcp_qdrant_path", path)
        }

        static func knowledgeBase(_ path: String) -> String {
            format("menu.mcp_knowledge_base", path)
        }

        static func modelCache(_ path: String) -> String {
            format("menu.mcp_model_cache", path)
        }

        static var stateRunning: String {
            string("menu.mcp_state_running")
        }

        static var stateInitializing: String {
            string("menu.mcp_state_initializing")
        }

        static var stateRestarting: String {
            string("menu.mcp_state_restarting")
        }

        static var stateStopped: String {
            string("menu.mcp_state_stopped")
        }

        static var stateCrashed: String {
            string("menu.mcp_state_crashed")
        }

        static var notifyCrashedTitle: String {
            string("notify.mcp_crashed_title")
        }

        static func notifyCrashedBody(_ n: Int) -> String {
            format("notify.mcp_crashed", n)
        }

        static var envCheckTitle: String {
            string("notify.mcp_env_check_title")
        }

        static var envPythonMissing: String {
            string("notify.mcp_env_python_missing")
        }

        static var envVenvMissing: String {
            string("notify.mcp_env_venv_missing")
        }
    }
}

// MARK: - Proxy Strings

extension L10n {
    enum Proxy {
        static var stateRunning: String {
            string("menu.proxy_state_running")
        }

        static var stateStopped: String {
            string("menu.proxy_state_stopped")
        }

        static var stateCrashed: String {
            string("menu.proxy_state_crashed")
        }

        static var disabled: String {
            string("menu.proxy_disabled")
        }

        static func today(_ inputK: Double, _ outputK: Double) -> String {
            format("menu.proxy_today", inputK, outputK)
        }

        static func requests(_ total: Int, _ invalid: Int, _ pct: Double) -> String {
            format("menu.proxy_requests", total, invalid, pct)
        }
    }
}
