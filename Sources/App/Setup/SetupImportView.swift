import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-launch import step: pick a ZIP, choose external destinations and conflict policy.
struct SetupImportView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Setup.importTitle)
                .font(.title3.bold())
            Text(L10n.Setup.importHint)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let plan = model.plan {
                summary(plan)
            } else {
                HStack(spacing: 8) {
                    Button(L10n.Setup.chooseArchive) { chooseArchive() }
                        .disabled(model.validating)
                    if model.validating {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if let error = model.error {
                Text(L10n.Setup.error(message: error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Spacer()
            footer
        }
        .padding(20)
    }

    @ViewBuilder
    private func summary(_ plan: ArchiveImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                L10n.Setup.importSummary(
                    version: plan.manifest.appVersion,
                    files: "\(plan.manifest.files.count)",
                )
            )
            .font(.callout)
            if plan.manifest.includesSecrets {
                Text(L10n.Setup.includesSecrets)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !plan.manifest.external.isEmpty {
                Text(L10n.Setup.externalTitle)
                    .font(.callout.bold())
                    .padding(.top, 4)
                ForEach(plan.manifest.external, id: \.role) { record in
                    externalRow(record)
                }
            }
        }
    }

    private func externalRow(_ record: ExternalDir) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.roleTitle(record.role))
                .font(.callout.bold())
            HStack(spacing: 8) {
                Text(
                    L10n.Setup.destinationLabel(
                        path: model.destination(for: record.role)?.path ?? record.originalPath,
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer()
                Button(L10n.Setup.chooseDestination) {
                    chooseDestination(for: record.role)
                }
            }
            if let conflict = model.conflict(for: record.role), conflict.existingCount > 0 {
                HStack(spacing: 8) {
                    Text(L10n.Setup.conflictCount(count: "\(conflict.existingCount)"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Picker("", selection: policyBinding(for: record.role)) {
                        Text(L10n.Setup.policySkip)
                            .tag(ExternalConflictPolicy.skipExisting)
                        Text(L10n.Setup.policyOverwrite)
                            .tag(ExternalConflictPolicy.overwrite)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.validating {
                ProgressView().controlSize(.small)
                Text(L10n.Setup.busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.plan != nil {
                Button(L10n.Setup.chooseAgain) { model.abortImport() }
                Button(L10n.Setup.importButton) { model.importSelectedArchive() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.validating)
            } else {
                Button(L10n.Setup.skipImport) { model.skipImport() }
            }
        }
    }

    private func policyBinding(for role: ExternalRole) -> Binding<ExternalConflictPolicy> {
        Binding(
            get: { model.policy(for: role) },
            set: { model.setPolicy($0, for: role) },
        )
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseArchive(url)
    }

    private func chooseDestination(for role: ExternalRole) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.destination(for: role)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setDestination(url, for: role)
    }
}
