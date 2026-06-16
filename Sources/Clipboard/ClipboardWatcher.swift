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
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        let interval = ConfigManager.shared.config.clipboard.pollInterval
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.1), repeats: true) {
            [weak self] _ in
            self?.check()
        }
        print("[Clipboard] Watcher started (poll: \(ConfigManager.shared.config.clipboard.pollInterval)s)")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        print("[Clipboard] Watcher stopped")
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

        guard let pbItem = pasteboard.pasteboardItems?.first else { return }

        // 判断类型并存储
        if let str = pbItem.string(forType: .string) {
            let clip = ClipboardItem(type: "text",
                                      content: str.data(using: .utf8) ?? Data(),
                                      application: pasteboardOwner())
            try? storage.add(clip)
        } else if let _ = pbItem.data(forType: .fileURL) {
            if let data = pbItem.data(forType: .fileURL) {
                let clip = ClipboardItem(type: "file", content: data,
                                          application: pasteboardOwner())
                try? storage.add(clip)
            }
        } else if let _ = pbItem.data(forType: .tiff) {
            if let data = pbItem.data(forType: .tiff) {
                let clip = ClipboardItem(type: "image", content: data,
                                          application: pasteboardOwner())
                try? storage.add(clip)
            }
        }
    }

    private func pasteboardOwner() -> String? {
        // 尝试从额外 pasteboard 类型获取来源
        if let source = pasteboard.string(forType: .init("org.nspasteboard.source")) {
            return source
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
