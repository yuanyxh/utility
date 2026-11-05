import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(L10n.Settings.groupApp) {
                    Toggle(
                        L10n.Settings.fieldHideDockIcon,
                        isOn: $model.config.app.hideDockIcon,
                    )
                    Toggle(
                        L10n.Settings.fieldShowTerminalOnLaunch,
                        isOn: $model.config.app.showTerminalOnLaunch,
                    )
                }

                Section(L10n.Settings.groupGeneral) {
                    Picker(
                        L10n.Settings.fieldLanguage,
                        selection: $model.config.general.language,
                    ) {
                        Text(L10n.Settings.languageSystem).tag("")
                        Text(L10n.Settings.languageZh).tag("zh")
                        Text(L10n.Settings.languageEn).tag("en")
                    }
                    TextField(
                        L10n.Settings.fieldHttpTimeout,
                        value: $model.config.general.httpTimeout,
                        format: .number,
                    )
                    TextField(
                        L10n.Settings.fieldAiTimeout,
                        value: $model.config.general.aiTimeout,
                        format: .number,
                    )
                }

                Section(L10n.Settings.groupClipboard) {
                    TextField(
                        L10n.Settings.fieldClipboardMaxDays,
                        value: $model.config.clipboard.maxDays,
                        format: .number,
                    )
                    TextField(
                        L10n.Settings.fieldClipboardPollInterval,
                        value: $model.config.clipboard.pollInterval,
                        format: .number,
                    )
                    hotkeyField(
                        L10n.Settings.fieldClipboardHotkey,
                        text: $model.config.clipboard.hotkey,
                    )
                }

                Section(L10n.Settings.groupTranslation) {
                    hotkeyField(
                        L10n.Settings.fieldTranslationHotkey,
                        text: $model.config.translation.hotkey,
                    )
                    hotkeyField(
                        L10n.Settings.fieldTranslationHotkeyOcr,
                        text: $model.config.translation.hotkeyOCR,
                    )
                    languagePicker(
                        L10n.Settings.fieldSourceLang,
                        selection: $model.config.translation.sourceLang,
                    )
                    languagePicker(
                        L10n.Settings.fieldTargetLang,
                        selection: $model.config.translation.targetLang,
                    )
                }

                Section(L10n.Settings.groupKnowledge) {
                    Toggle(
                        L10n.Settings.fieldKnowledgeEnabled,
                        isOn: $model.config.knowledge.enabled,
                    )
                    Toggle(
                        L10n.Settings.fieldKnowledgeAutoShow,
                        isOn: $model.config.knowledge.autoShowEnabled,
                    )
                    TextField(
                        L10n.Settings.fieldRefillInterval,
                        value: $model.config.knowledge.refillIntervalMinutes,
                        format: .number,
                    )
                    hotkeyField(
                        L10n.Settings.fieldKnowledgeHotkey,
                        text: $model.config.knowledge.hotkey,
                    )
                }

                Section(L10n.Settings.groupTerminal) {
                    Toggle(
                        L10n.Settings.fieldTerminalEnabled,
                        isOn: $model.config.terminal.enabled,
                    )
                    TextField(
                        L10n.Settings.fieldFontSize,
                        value: $model.config.terminal.fontSize,
                        format: .number,
                    )
                    Toggle(
                        L10n.Settings.fieldAlwaysOnTop,
                        isOn: $model.config.terminal.alwaysOnTop,
                    )
                    pathField(
                        L10n.Settings.fieldShell,
                        text: $model.config.terminal.shell,
                        choose: chooseFile,
                    )
                    pathField(
                        L10n.Settings.fieldWorkingDirectory,
                        text: $model.config.terminal.workingDirectory,
                        choose: chooseDirectory,
                    )
                }

                Section(L10n.Settings.groupRss) {
                    Toggle(
                        L10n.Settings.fieldRssDailyEnabled,
                        isOn: $model.config.rss.daily.enabled,
                    )
                    TextField(
                        L10n.Settings.fieldRssDailyCron,
                        text: $model.config.rss.daily.cron,
                    )
                    TextField(
                        L10n.Settings.fieldMaxAgeDays,
                        value: $model.config.rss.daily.maxAgeDays,
                        format: .number,
                    )
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                statusText
                Spacer()
                Button(L10n.Menu.openConfig) {
                    EventBus.shared.publish(AppEvent.openConfigEditor)
                }
                Button(L10n.Settings.reload) { model.reloadFromDisk() }
                Button(L10n.Settings.save) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    model.save()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(12)

            Text(L10n.Settings.backupHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    /// Keeps a hand-edited value selectable even when it is outside the offered list.
    private func languagePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(TranslationLanguages.all) { language in
                Text(language.name).tag(language.code)
            }
            let known = TranslationLanguages.all.contains { $0.code == selection.wrappedValue }
            if !known, !selection.wrappedValue.isEmpty {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }

    private func hotkeyField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: text)
            Text(L10n.Settings.fieldRestartHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pathField(
        _ title: String,
        text: Binding<String>,
        choose: @escaping (Binding<String>) -> Void,
    ) -> some View {
        HStack(spacing: 8) {
            TextField(title, text: text)
            Button(L10n.Settings.choose) { choose(text) }
        }
    }

    private func chooseDirectory(_ binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory(binding.wrappedValue)
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func chooseFile(_ binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL =
            initialDirectory((binding.wrappedValue as NSString).deletingLastPathComponent)
            ?? URL(fileURLWithPath: "/bin")
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    /// Start browsing from an existing path; nil means the panel picks its default.
    private func initialDirectory(_ raw: String) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return nil
        }
        let directory =
            isDir.boolValue ? expanded : (expanded as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: directory)
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .saved:
            Text(L10n.Settings.saved).foregroundStyle(.green)
        case .failed(let message):
            Text(message).foregroundStyle(.red).lineLimit(3)
        }
    }
}
