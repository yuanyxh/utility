import SwiftUI

/// Dependency check step.
struct SetupCheckView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Setup.checkTitle)
                .font(.title3.bold())
            Text(L10n.Setup.checkHint)
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Setup.busy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { item in
                        itemRow(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = model.error {
                Text(L10n.Setup.error(message: error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Spacer()
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.Setup.recheck) { model.startCheck() }
                    .disabled(model.checking)
                Button(L10n.Setup.next) { model.nextFromCheck() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checking)
            }
        }
        .padding(20)
    }

    private func itemRow(_ item: SetupItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(item.state))
                .foregroundStyle(color(item.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.itemTitle(item.id))
                    .font(.callout.bold())
                if let version = item.version, !version.isEmpty {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let path = item.path, !path.isEmpty {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func symbol(_ state: SetupState) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .optional: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ state: SetupState) -> Color {
        switch state {
        case .ok: .green
        case .missing: .red
        case .optional: .secondary
        case .failed: .orange
        }
    }
}

/// Install step with confirmation, progress and a log tail.
struct SetupInstallView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Setup.installTitle)
                .font(.title3.bold())
            Text(L10n.Setup.installHint)
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.missingRequired.isEmpty {
                Text(L10n.Setup.noMissing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.missingRequired) { item in
                    Text("• \(model.itemTitle(item.id))")
                        .font(.callout)
                }
                if model.missingRequired.contains(where: { $0.id == .homebrew }) {
                    Text(L10n.Setup.homebrewHint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(L10n.Setup.homebrewScript(url: SetupInstaller.homebrewScriptURL))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            if model.installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Setup.installingLabel)
                        .font(.caption)
                }
            }
            SetupLogView(lines: model.logLines)

            if let error = model.error {
                Text(L10n.Setup.error(message: error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Spacer()
            HStack(spacing: 10) {
                Button(L10n.Setup.startInstall) { model.startInstall() }
                    .disabled(model.installing || model.missingRequired.isEmpty)
                Spacer()
                Button(L10n.Setup.recheck) { model.startCheck() }
                    .disabled(model.installing || model.checking)
                Button(L10n.Setup.next) { model.nextFromInstall() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.installing || model.checking)
            }
        }
        .padding(20)
    }
}

/// Final step.
struct SetupDoneView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Setup.doneTitle)
                .font(.title3.bold())
            Text(L10n.Setup.doneHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.allRequiredOK {
                Text(L10n.Setup.checkHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Spacer()
                Button(L10n.Setup.finish) { model.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct SetupLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 170)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _, _ in
                guard let last = lines.indices.last else { return }
                withAnimation(nil) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
