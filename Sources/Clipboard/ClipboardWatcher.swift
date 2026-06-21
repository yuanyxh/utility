import Cocoa

/// 剪切板监视器
/// 以 config 中配置的间隔（默认 0.3s）轮询 NSPasteboard changeCount
public final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let storage: ClipboardStorage

    public init(storage: ClipboardStorage) {
        self.storage = storage
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        let interval = ConfigManager.shared.config.clipboard.pollInterval
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.1), repeats: true) {
            [weak self] _ in
            self?.check()
        }
        debugLog("[Clipboard] Watcher started (poll: \(ConfigManager.shared.config.clipboard.pollInterval)s)")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        debugLog("[Clipboard] Watcher stopped")
    }

    // MARK: - Check

    /// 标记当前 pasteboard 变化为"已处理"，让下次 check() 跳过
    /// 用于面板自己写入 pasteboard 后避免 watcher 重复处理
    public func skipCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    private func check() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName,
           ConfigManager.shared.config.clipboard.excludeApps.contains(frontApp)
        {
            return
        }

        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else { return }

        // ── 1. 文件 URL（Finder 复制，含图片/文件夹/任意文件）──
        let allFileURLs: [URL] = pbItems.compactMap { item in
            guard let urlStr = item.string(forType: .fileURL),
                  let url = URL(string: urlStr) else { return nil }
            return url
        }

        if !allFileURLs.isEmpty {
            storeFiles(allFileURLs)
            return
        }

        // ── 2. 无文件 URL，有图片数据（浏览器右键复制图片、截图）──
        if let imageData = extractImageData(from: pbItems) {
            storeImageFromData(imageData)
            return
        }

        // ── 3. 富文本 HTML（网页复制）──
        if let htmlItem = pbItems.first(where: { $0.types.contains(.html) }),
           let html = htmlItem.string(forType: .html)
        {
            let plainText = htmlItem.string(forType: .string)
            let clip = ClipboardItem(type: "html", content: html.data(using: .utf8) ?? Data(),
                                     application: plainText ?? pasteboardOwner())
            try? storage.add(clip)
            return
        }

        // ── 4. 纯文本 ──
        if let textItem = pbItems.first(where: { $0.types.contains(.string) }),
           let str = textItem.string(forType: .string)
        {
            let clip = ClipboardItem(type: "text",
                                     content: str.data(using: .utf8) ?? Data(),
                                     application: pasteboardOwner())
            try? storage.add(clip)
            return
        }

        // 无匹配类型，静默忽略
    }

    // MARK: - File storage

    /// 统一存储文件：1 个 → file，多个 → file_batch
    private func storeFiles(_ urls: [URL]) {
        if urls.count == 1 {
            if let data = try? JSONEncoder().encode(["path": urls[0].path]) {
                let clip = ClipboardItem(type: "file", content: data,
                                         application: urls[0].lastPathComponent)
                try? storage.add(clip)
            }
        } else {
            let paths = urls.map { $0.path }
            if let data = try? JSONEncoder().encode(["paths": paths]) {
                let clip = ClipboardItem(type: "file_batch", content: data,
                                         application: L10n.Clipboard.fileCount(urls.count))
                try? storage.add(clip)
            }
        }
    }

    /// 浏览器图片数据 → 写临时文件 → 存为 file
    private func storeImageFromData(_ imageData: Data) {
        let filename = "clip_\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = AppPaths.clipCacheDir.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL)
            if let data = try? JSONEncoder().encode(["path": fileURL.path]) {
                let clip = ClipboardItem(type: "file", content: data,
                                         application: filename)
                try? storage.add(clip)
            }
        } catch {
            debugLog("[Clipboard] image write failed: \(error)")
        }
    }

    /// 从 pasteboard items 提取第一张图片的原始数据
    private func extractImageData(from items: [NSPasteboardItem]) -> Data? {
        for item in items {
            for type in PasteboardImageTypes.all {
                if let data = item.data(forType: type) {
                    return data
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func pasteboardOwner() -> String? {
        if let source = pasteboard.string(forType: .init("org.nspasteboard.source")) {
            return source
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
