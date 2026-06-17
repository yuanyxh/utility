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

        // 收集所有图片
        let images: [ImageClip] = pbItems.compactMap { item in
            for type in Self.imageUTIs {
                if let data = item.data(forType: type) {
                    return ImageClip(format: type.rawValue, data: data)
                }
            }
            return nil
        }

        if images.count > 1 {
            // 多个图片 → batch 存储
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: images, requiringSecureCoding: false) {
                let clip = ClipboardItem(type: "image_batch", content: data, application: pasteboardOwner())
                try? storage.add(clip)
            }
        } else if images.count == 1 {
            // 单个图片 → 存原始数据
            let clip = ClipboardItem(type: "image", content: images[0].data, application: pasteboardOwner())
            try? storage.add(clip)
        } else if let firstText = pbItems.first(where: { $0.types.contains(.string) }),
                  let str = firstText.string(forType: .string) {
            // 文本
            let clip = ClipboardItem(type: "text",
                                      content: str.data(using: .utf8) ?? Data(),
                                      application: pasteboardOwner())
            try? storage.add(clip)
        }
    }

    private func pasteboardOwner() -> String? {
        if let source = pasteboard.string(forType: .init("org.nspasteboard.source")) {
            return source
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
