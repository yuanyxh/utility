import Cocoa
import SwiftUI

/// First-launch wizard. Runs a modal session before `ConfigManager.load()` so an imported
/// archive is in place before any database opens.
@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SetupWindowController()

    private var model: SetupModel!
    private var languageObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false,
        )
        window.title = L10n.Setup.title
        window.isReleasedWhenClosed = false
        super.init(window: window)

        model = SetupModel { [weak self] in
            self?.finish()
        }
        window.contentViewController = NSHostingController(rootView: SetupRootView(model: model))
        window.delegate = self
        window.center()
        AppWindowRegistry.register(window)
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.title = L10n.Setup.title
            }
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func runFirstLaunch() {
        guard let window else { return }
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    func windowWillClose(_: Notification) {
        if !model.validating {
            model.abortImport()
        }
        finish()
    }

    private func finish() {
        NSApp.stopModal(withCode: .OK)
        window?.orderOut(nil)
    }
}

/// Wizard shell: header, step counter and the current step.
struct SetupRootView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.Setup.title)
                    .font(.headline)
                Spacer()
                Text("\(model.step.rawValue + 1) / 4")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Group {
                switch model.step {
                case .importConfig:
                    SetupImportView(model: model)
                case .check:
                    SetupCheckView(model: model)
                case .install:
                    SetupInstallView(model: model)
                case .done:
                    SetupDoneView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 560)
    }
}
