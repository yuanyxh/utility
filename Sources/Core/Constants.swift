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
