import Cocoa

/// 图片裁剪数据（用于 batch 存储）
public struct ImageClip: Codable {
    public let format: String  // UTI, e.g. "public.png"
    public let data: Data
}

/// 剪切板监视器
/// 以 config 中配置的间隔（默认 0.3s）轮询 NSPasteboard changeCount
public final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let storage: ClipboardStorage

    private static let imageUTIs: [NSPasteboard.PasteboardType] = [
        .tiff,
        .png,
        .init("public.jpeg"),
        .init("public.heic"),
        .init("com.compuserve.gif"),
        .init("public.webp"),
        .init("public.bmp"),
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "gif", "webp", "bmp"
    ]

    public init(storage: ClipboardStorage) {
        self.storage = storage
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        let interval = ConfigManager.shared.config.clipboard.pollInterval
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.1), repeats: true) {
            [weak self] _ in
            self?.check()
        }
        Log.debug("[Clipboard] Watcher started (poll: \(ConfigManager.shared.config.clipboard.pollInterval)s)")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        Log.debug("[Clipboard] Watcher stopped")
    }

    // MARK: - Check

    private func check() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // 排除应用
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName,
           ConfigManager.shared.config.clipboard.excludeApps.contains(frontApp) {
            return
        }

        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else { return }

        // 1. 从 pasteboard 直接获取图片（浏览器、截图工具等）
        var allImages: [(clip: ImageClip, source: String)] = pbItems.compactMap { item in
            for type in Self.imageUTIs {
                if let data = item.data(forType: type) {
                    return (ImageClip(format: type.rawValue, data: data),
                            pasteboardOwner() ?? "")
                }
            }
            // 2. 从文件 URL 读取（Finder 复制）
            if let urlStr = item.string(forType: .fileURL),
               let url = URL(string: urlStr),
               Self.imageExtensions.contains(url.pathExtension.lowercased()),
               let data = try? Data(contentsOf: url) {
                let uti = Self.utiForExtension(url.pathExtension)
                return (ImageClip(format: uti, data: data),
                        url.lastPathComponent)  // 存文件名
            }
            return nil
        }

        if allImages.count > 1 {
            // 多张图片 → batch
            let clips = allImages.map { $0.clip }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: clips, requiringSecureCoding: false) {
                let appName = allImages.first?.source ?? pasteboardOwner()
                let clip = ClipboardItem(type: "image_batch", content: data, application: appName)
                try? storage.add(clip)
            }
        } else if allImages.count == 1 {
            // 单张图片 — 编码格式信息供 paste 时还原原始类型
            let dict: [String: Any] = [
                "format": allImages[0].clip.format,
                "data": allImages[0].clip.data,
            ]
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: dict, requiringSecureCoding: false) {
                let clip = ClipboardItem(type: "image", content: data,
                                          application: allImages[0].source)
                try? storage.add(clip)
            }
        } else if let firstText = pbItems.first(where: { $0.types.contains(.string) }),
                  let str = firstText.string(forType: .string) {
            // 文本
            let clip = ClipboardItem(type: "text",
                                      content: str.data(using: .utf8) ?? Data(),
                                      application: pasteboardOwner())
            try? storage.add(clip)
        }
    }

    // MARK: - Helpers

    private static func utiForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "public.png"
        case "jpg", "jpeg": return "public.jpeg"
        case "tiff", "tif": return "public.tiff"
        case "heic", "heif": return "public.heic"
        case "gif": return "com.compuserve.gif"
        case "webp": return "public.webp"
        case "bmp": return "public.bmp"
        default: return "public.png"
        }
    }

    private func pasteboardOwner() -> String? {
        if let source = pasteboard.string(forType: .init("org.nspasteboard.source")) {
            return source
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
