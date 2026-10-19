import Cocoa

/// Clipboard watcher
/// Polls NSPasteboard changeCount at the interval configured in config (default 0.3s)
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
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Check

    /// Mark the current pasteboard change as "already handled" so the next check() skips it
    /// Used so that after the panel itself writes to the pasteboard the watcher does not re-process it
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

        // ── 1. File URL (Finder copy, including images/folders/arbitrary files) ──
        let allFileURLs: [URL] = pbItems.compactMap { item in
            guard let urlStr = item.string(forType: .fileURL),
                  let url = URL(string: urlStr)
            else { return nil }
            return url
        }

        if !allFileURLs.isEmpty {
            storeFiles(allFileURLs)
            return
        }

        // ── 2. No file URL, but image data (copy image via browser context menu, screenshot) ──
        if let imageData = extractImageData(from: pbItems) {
            storeImageFromData(imageData)
            return
        }

        // ── 3. Rich-text HTML (copied from a web page) ──
        if let htmlItem = pbItems.first(where: { $0.types.contains(.html) }),
           let html = htmlItem.string(forType: .html)
        {
            let plainText = htmlItem.string(forType: .string)
            let clip = ClipboardItem(
                type: "html", content: html.data(using: .utf8) ?? Data(),
                application: plainText ?? pasteboardOwner(),
            )
            try? storage.add(clip)
            return
        }

        // ── 4. Plain text ──
        if let textItem = pbItems.first(where: { $0.types.contains(.string) }),
           let str = textItem.string(forType: .string)
        {
            let clip = ClipboardItem(
                type: "text",
                content: str.data(using: .utf8) ?? Data(),
                application: pasteboardOwner(),
            )
            try? storage.add(clip)
            return
        }

        // No matching type, silently ignore
    }

    // MARK: - File storage

    /// Unified file storage: 1 → file, multiple → file_batch
    private func storeFiles(_ urls: [URL]) {
        if urls.count == 1 {
            if let data = try? JSONEncoder().encode(["path": urls[0].path]) {
                let clip = ClipboardItem(
                    type: "file", content: data,
                    application: urls[0].lastPathComponent,
                )
                try? storage.add(clip)
            }
        } else {
            let paths = urls.map(\.path)
            if let data = try? JSONEncoder().encode(["paths": paths]) {
                let clip = ClipboardItem(
                    type: "file_batch", content: data,
                    application: L10n.Clipboard.fileCount(count: urls.count),
                )
                try? storage.add(clip)
            }
        }
    }

    /// Browser image data → write temp file → store as file
    private func storeImageFromData(_ imageData: Data) {
        let filename = "clip_\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = AppPaths.clipCacheDir.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL)
            if let data = try? JSONEncoder().encode(["path": fileURL.path]) {
                let clip = ClipboardItem(
                    type: "file", content: data,
                    application: filename,
                )
                try? storage.add(clip)
            }
        } catch {
            debugLog("[Clipboard] image write failed: \(error)")
        }
        // After a successful save, also clean up expired image cache (retention matches clipboard maxDays), move to Trash
        cleanupOldClips()
    }

    /// Clean up expired clipboard image cache (retention matches clipboard.maxDays), move to Trash
    private func cleanupOldClips() {
        let maxDays = ConfigManager.shared.config.clipboard.maxDays
        let cutoff = Date().addingTimeInterval(-Double(maxDays * 86400))
        let fm = FileManager.default
        let dir = AppPaths.clipCacheDir
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [],
        ) else { return }
        for file in files where file.pathExtension == "png" {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if mtime < cutoff {
                try? fm.trashItem(at: file, resultingItemURL: nil)
                debugLog("[Clipboard] trash expired clip: \(file.lastPathComponent)")
            }
        }
    }

    /// Extract the raw data of the first image from pasteboard items
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
