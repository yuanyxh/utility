import Cocoa
import ServiceManagement

public final class MenuBarManager: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var reloadItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var rssMenuItem: NSMenuItem!
    private var tasksMenuItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var rssFetchTask: Task<Void, Never>?

    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
        startNetworkMonitor()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil
        )
    }

    @objc private func onLanguageChanged() {
        refreshAllTitles()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "utility-network-speed"

        let view = NetworkSpeedView()
        view.onClick = { [weak self] event in
            guard let self, let menu = self.statusItem.menu,
                  let v = self.statusItem.value(forKey: "view") as? NSView else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: v)
        }
        statusItem.setValue(view, forKey: "view")
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        reloadItem = NSMenuItem(title: L10n.Menu.reloadConfig, action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        launchAtLoginItem = NSMenuItem(title: L10n.Menu.launchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        // ── RSS ──
        rssMenuItem = NSMenuItem(title: L10n.Menu.rss, action: nil, keyEquivalent: "")
        rssMenuItem.submenu = NSMenu()
        menu.addItem(rssMenuItem)

        menu.addItem(NSMenuItem.separator())

        // ── Tasks ──
        tasksMenuItem = NSMenuItem(title: L10n.Menu.tasks, action: nil, keyEquivalent: "")
        tasksMenuItem.submenu = NSMenu()
        menu.addItem(tasksMenuItem)

        menu.addItem(NSMenuItem.separator())

        clearItem = NSMenuItem(title: L10n.Menu.clearClipboard, action: #selector(clearClipboard), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        quitItem = NSMenuItem(title: L10n.Menu.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        refreshRSSItem()
        refreshTasksItem()
    }

    private func refreshRSSItem() {
        let count = (try? RSSManager.shared.unreadCount()) ?? 0
        let sub = NSMenu()

        let fetchItem = NSMenuItem(title: L10n.Menu.rssFetch, action: #selector(rssFetch), keyEquivalent: "")
        fetchItem.target = self
        sub.addItem(fetchItem)

        let markReadItem = NSMenuItem(title: L10n.Menu.rssMarkAllRead, action: #selector(rssMarkAllRead), keyEquivalent: "")
        markReadItem.target = self
        sub.addItem(markReadItem)

        rssMenuItem.title = count > 0 ? L10n.Menu.rssUnread(count) : L10n.Menu.rss
        rssMenuItem.submenu = sub
    }

    private func refreshTasksItem() {
        let tasks = ConfigManager.shared.config.tasks
        let sub = NSMenu()

        for task in tasks {
            let item = NSMenuItem(
                title: task.name,
                action: task.enabled ? #selector(taskTrigger(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = task.enabled ? self : nil
            item.isEnabled = task.enabled
            item.representedObject = task.name
            sub.addItem(item)
        }

        tasksMenuItem.title = tasks.isEmpty ? L10n.Menu.tasks : L10n.Menu.tasksCount(tasks.count)
        tasksMenuItem.submenu = sub
    }

    // MARK: - Network

    private func startNetworkMonitor() {
        let monitor = NetworkSpeedMonitor.shared
        monitor.onUpdate = { [weak self] up, down in
            guard let view = self?.statusItem.value(forKey: "view") as? NetworkSpeedView else { return }
            view.update(up: up, down: down)
        }
        monitor.start()
    }

    // MARK: - RSS Actions

    @objc private func rssFetch() {
        rssFetchTask?.cancel()
        rssFetchTask = Task {
            do {
                let new = try await RSSManager.shared.fetchAll()
                guard !Task.isCancelled else { return }
                debugLog("[MenuBar] RSS fetch: \(new.count) new items")
            } catch {
                guard !Task.isCancelled else { return }
                debugLog("[MenuBar] RSS fetch failed: \(error)")
                NotificationManager.shared.error(L10n.Menu.rssFetchFailed, error.localizedDescription)
            }
        }
    }

    @objc private func rssMarkAllRead() {
        do {
            try RSSManager.shared.markAllAsRead()
            debugLog("[MenuBar] RSS marked all read")
        } catch {
            debugLog("[MenuBar] RSS mark all read failed: \(error)")
        }
    }

    // MARK: - Task Actions

    @objc private func taskTrigger(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let task = ConfigManager.shared.config.tasks.first(where: { $0.name == name && $0.enabled })
        else { return }

        DispatchQueue.global(qos: .utility).async {
            let result = TaskExecutor.execute(task.exec)
            if result.success {
                debugLog("[MenuBar] Task '\(name)' triggered OK")
            } else {
                let errMsg = result.error.isEmpty ? "exit code != 0" : String(result.error.prefix(200))
                debugLog("[MenuBar] Task '\(name)' FAILED: \(errMsg)")
                DispatchQueue.main.async {
                    NotificationManager.shared.error(L10n.Menu.taskFailed(name), errMsg)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginItem.state = .off
                debugLog("[LoginItem] Unregistered")
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginItem.state = .on
                debugLog("[LoginItem] Registered")
            }
        } catch {
            debugLog("[LoginItem] Failed: \(error)")
            NotificationManager.shared.error(L10n.Menu.launchAtLoginFailed, error.localizedDescription)
        }
    }

    // MARK: - Title Refresh

    func refreshAllTitles() {
        reloadItem.title = L10n.Menu.reloadConfig
        launchAtLoginItem.title = L10n.Menu.launchAtLogin
        rssMenuItem.title = L10n.Menu.rss
        tasksMenuItem.title = L10n.Menu.tasks
        clearItem.title = L10n.Menu.clearClipboard
        quitItem.title = L10n.Menu.quit
    }

    @objc private func reloadConfig() {
        do {
            try ConfigManager.shared.reload()
            refreshAllTitles()
            refreshRSSItem()
            refreshTasksItem()
        } catch {
            debugLog("[MenuBar] Reload failed: \(error)")
            NotificationManager.shared.error(L10n.Menu.configReloadFailed, error.localizedDescription)
        }
    }

    @objc private func clearClipboard() {
        let db = AppDatabase.shared.dbQueue
        try? db?.write { db in
            try db.execute(literal: "DELETE FROM clipboard_item")
        }
        debugLog("[MenuBar] Clipboard cleared")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NetworkSpeedView

private final class NetworkSpeedView: NSView {
    private let upLabel   = NSTextField(labelWithString: "")
    private let downLabel = NSTextField(labelWithString: "")

    var onClick: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        upLabel.font   = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        downLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        upLabel.alignment   = .right
        downLabel.alignment = .right

        let stack = NSStackView(views: [upLabel, downLabel])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .trailing
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        update(up: "--", down: "--")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event)
    }

    override var intrinsicContentSize: NSSize {
        let upSz   = upLabel.intrinsicContentSize
        let downSz = downLabel.intrinsicContentSize
        return NSSize(
            width: max(upSz.width, downSz.width),
            height: upSz.height + downSz.height
        )
    }

    func update(up: String, down: String) {
        let (paddedUp, paddedDown) = pad(up: up, down: down)
        upLabel.stringValue   = paddedUp
        downLabel.stringValue = paddedDown
        invalidateIntrinsicContentSize()
        superview?.layoutSubtreeIfNeeded()
    }

    // MARK: - Padding

    private func pad(up: String, down: String) -> (String, String) {
        let upInt   = String(up.prefix(while: { $0 != "." }))
        let downInt = String(down.prefix(while: { $0 != "." }))
        let upRest  = String(up.dropFirst(upInt.count))
        let downRest = String(down.dropFirst(downInt.count))

        let maxLen = max(upInt.count, downInt.count)
        let padUp   = String(repeating: "0", count: maxLen - upInt.count) + upInt
        let padDown = String(repeating: "0", count: maxLen - downInt.count) + downInt

        return ("↑ " + padUp + upRest, "↓ " + padDown + downRest)
    }
}
