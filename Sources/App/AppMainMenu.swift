import Cocoa

/// App main menu. Standard selectors use a nil target so the responder chain dispatches them.
@MainActor
enum AppMainMenu {
    /// Lightweight menu target: avoids building the settings window during launch.
    private final class SettingsMenuTarget: NSObject {
        @objc func showSettings() {
            MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        }
    }

    private static let settingsTarget = SettingsMenuTarget()
    private static var languageObserver: NSObjectProtocol?

    static func install() {
        guard languageObserver == nil else {
            rebuild()
            return
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated { rebuild() }
        }
        rebuild()
    }

    static func rebuild() {
        let servicesMenu = NSMenu(title: L10n.Menu.services)

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(
            item(
                L10n.Menu.appAbout, #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            ))
        appMenu.addItem(
            item(
                L10n.Menu.settings, #selector(SettingsMenuTarget.showSettings), ",",
                target: settingsTarget,
            ))
        appMenu.addItem(.separator())
        appMenu.addItem(item(L10n.Menu.services, nil, submenu: servicesMenu))
        appMenu.addItem(.separator())
        appMenu.addItem(item(L10n.Menu.appHide, #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(
            item(
                L10n.Menu.appHideOthers, #selector(NSApplication.hideOtherApplications(_:)),
                "h", [.command, .option],
            ))
        appMenu.addItem(
            item(
                L10n.Menu.appShowAll, #selector(NSApplication.unhideAllApplications(_:)),
            ))
        appMenu.addItem(.separator())
        appMenu.addItem(item(L10n.Menu.quit, #selector(NSApplication.terminate(_:)), "q"))

        let editMenu = NSMenu(title: L10n.Menu.edit)
        editMenu.addItem(item(L10n.Menu.editUndo, Selector(("undo:")), "z"))
        editMenu.addItem(
            item(
                L10n.Menu.editRedo, Selector(("redo:")), "z", [.command, .shift],
            ))
        editMenu.addItem(.separator())
        editMenu.addItem(item(L10n.Menu.editCut, #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item(L10n.Menu.editCopy, #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item(L10n.Menu.editPaste, #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item(L10n.Menu.editDelete, #selector(NSText.delete(_:))))
        editMenu.addItem(.separator())
        editMenu.addItem(item(L10n.Menu.editSelectAll, #selector(NSText.selectAll(_:)), "a"))

        let windowMenu = NSMenu(title: L10n.Menu.window)
        windowMenu.addItem(
            item(
                L10n.Menu.windowClose, #selector(NSWindow.performClose(_:)), "w",
            ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            item(
                L10n.Menu.windowMinimize, #selector(NSWindow.performMiniaturize(_:)), "m",
            ))
        windowMenu.addItem(item(L10n.Menu.windowZoom, #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            item(
                L10n.Menu.windowFront, #selector(NSApplication.arrangeInFront(_:)),
            ))

        let main = NSMenu()
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: L10n.Menu.edit, action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)
        let windowItem = NSMenuItem(title: L10n.Menu.window, action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.servicesMenu = servicesMenu
        NSApp.windowsMenu = windowMenu
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Utility"
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        submenu: NSMenu? = nil,
        target: AnyObject? = nil,
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.submenu = submenu
        return item
    }
}
