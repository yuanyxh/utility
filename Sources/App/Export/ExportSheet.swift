import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet shown from Settings; scope checks, size hints, live progress and log tail.
struct ExportSheet: View {
    @StateObject private var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    init(model: ExportModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Export.title)
                .font(.headline)
            Text(L10n.Export.sectionHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            options

            if model.selection.isEmpty {
                Text(L10n.Export.noScope)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if model.includesSecrets {
                Text(L10n.Export.secretsWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            logView
            footer
        }
        .padding(16)
        .frame(width: 560, height: 540)
        .onAppear { model.prepare() }
        .interactiveDismissDisabled(model.isRunning)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.availableScopes, id: \.self) { scope in
                HStack(spacing: 8) {
                    Toggle(model.title(for: scope), isOn: binding(for: scope))
                        .disabled(model.isRunning)
                    Spacer()
                    Text(model.sizeText(for: scope) ?? "…")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(L10n.Export.includeSecrets, isOn: $model.includesSecrets)
                .disabled(model.isRunning)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 190)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.logLines.count) { _, _ in
                guard let last = model.logLines.indices.last else { return }
                withAnimation(nil) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusText
            Spacer()
            if case .done(let url) = model.status {
                Button(L10n.Export.reveal) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button(L10n.Export.cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isRunning)
            Button(L10n.Export.export) { chooseDestination() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.status {
        case .idle, .running:
            if model.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Export.running)
                        .font(.caption)
                }
            }
        case .done:
            Text(L10n.Export.done)
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(L10n.Export.failed(message: message))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func binding(for scope: ArchiveScope) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(scope) },
            set: { isOn in
                if isOn {
                    model.selection.insert(scope)
                } else {
                    model.selection.remove(scope)
                }
            },
        )
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
    }

    private func defaultName() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Utility-\(version)-\(formatter.string(from: Date())).zip"
    }
}
