import Foundation
import SwiftUI

/// Editable copy of the config shown by the settings window.
@MainActor
final class SettingsModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case saved
        case failed(String)
    }

    @Published var config: AppConfig
    @Published private(set) var status: Status = .idle

    private var languageObserver: NSObjectProtocol?

    init(config: AppConfig = ConfigManager.shared.config) {
        self.config = config
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    func reload() {
        config =
            (try? ConfigManager.shared.readConfigFromDisk())
            ?? ConfigManager.shared.config
        status = .idle
    }

    func save() {
        let errors = validate()
        guard errors.isEmpty else {
            status = .failed(errors.joined(separator: "\n"))
            return
        }
        do {
            try ConfigManager.shared.apply(config)
            config = ConfigManager.shared.config
            status = .saved
        } catch let error as ConfigApplyError {
            status = .failed(localize(error))
        } catch {
            status = .failed(L10n.Settings.saveFailed(message: error.localizedDescription))
        }
    }

    func validate() -> [String] {
        var errors: [String] = []

        func range(_ field: String, _ value: Double, _ low: Double, _ high: Double) {
            guard value < low || value > high else { return }
            errors.append(
                L10n.Settings.errorOutOfRange(
                    field: field, min: Self.number(low), max: Self.number(high),
                ))
        }
        func nonNegative(_ field: String, _ value: Double) {
            if value < 0 {
                errors.append(L10n.Settings.errorNegative(field: field))
            }
        }
        func hotkey(_ field: String, _ value: String) {
            if !HotkeyManager.isValid(value) {
                errors.append(L10n.Settings.errorHotkeyInvalid(field: field))
            }
        }

        range(L10n.Settings.fieldClipboardPollInterval, config.clipboard.pollInterval, 0.05, 5)
        range(L10n.Settings.fieldFontSize, config.terminal.fontSize, 8, 32)
        range(
            L10n.Settings.fieldRefillInterval,
            Double(config.knowledge.refillIntervalMinutes), 1, 1440,
        )
        nonNegative(L10n.Settings.fieldHttpTimeout, config.general.httpTimeout)
        nonNegative(L10n.Settings.fieldAiTimeout, config.general.aiTimeout)
        nonNegative(L10n.Settings.fieldClipboardMaxDays, Double(config.clipboard.maxDays))
        nonNegative(L10n.Settings.fieldMaxAgeDays, Double(config.rss.daily.maxAgeDays))

        hotkey(L10n.Settings.fieldClipboardHotkey, config.clipboard.hotkey)
        hotkey(L10n.Settings.fieldTranslationHotkey, config.translation.hotkey)
        hotkey(L10n.Settings.fieldTranslationHotkeyOcr, config.translation.hotkeyOCR)
        hotkey(L10n.Settings.fieldKnowledgeHotkey, config.knowledge.hotkey)

        return errors
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func localize(_ error: ConfigApplyError) -> String {
        switch error {
        case .fileTooLarge:
            L10n.Settings.errorFileTooLarge
        }
    }
}
