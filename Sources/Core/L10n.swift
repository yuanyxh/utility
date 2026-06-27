import Foundation

/// 轻量 i18n — JSON 字典方案
/// 默认中文（zh-Hans），支持英文（en）
/// 语言变更通过 NotificationCenter 发布 L10n.languageDidChange
enum L10n {
  static let languageDidChange = Notification.Name("L10n.languageDidChange")

  private static var dict: [String: String] = [:]
  static var currentLanguage: String {
    _lang
  }

  private static var _lang = "zh-Hans"

  /// 首次访问任一字符串时自动加载（系统首选语言）
  private static let _ready: Bool = {
    let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
    let lang = preferred.hasPrefix("zh") ? "zh-Hans" : "en"
    loadJSON(language: lang, notify: false)
    return true
  }()

  /// ConfigManager.load() 后调用 —— 按配置文件覆盖语言
  static func setup() {
    let config = ConfigManager.shared.config
    let lang = config.general.language.isEmpty ? preferredLanguage() : config.general.language
    loadJSON(language: lang, notify: true)
  }

  static func setLanguage(_ lang: String) {
    loadJSON(language: lang, notify: true)
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

    static var chatCompleted: String {
      string("notify.chat_completed")
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

    static var chat: String {
      string("prompt.chat")
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
