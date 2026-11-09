import Foundation
import SwiftUI
import Yams

/// Four-step first-launch state machine: import, check, install, done.
@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int {
        case importConfig = 0
        case check
        case install
        case done
    }

    @Published var step: Step = .importConfig
    @Published var items: [SetupItem] = []
    @Published var checking = false
    @Published var installing = false
    @Published var validating = false
    @Published var logLines: [String] = []
    @Published var error: String?
    @Published private(set) var plan: ArchiveImportPlan?
    @Published private(set) var decisions: [ExternalRestoreDecision] = []
    @Published private(set) var conflicts: [ExternalConflict] = []
    @Published private(set) var currentConfig = AppConfig()

    private let configDir = AppPaths.configDir
    private let onFinish: () -> Void
    private var validationToken = 0

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var missingRequired: [SetupItem] {
        items.filter { $0.state == .missing && $0.isRequired }
    }

    var allRequiredOK: Bool {
        missingRequired.isEmpty
    }

    func itemTitle(_ id: SetupItemID) -> String {
        switch id {
        case .xcodeCLT: L10n.Setup.itemXcode
        case .homebrew: L10n.Setup.itemHomebrew
        case .python: L10n.Setup.itemPython
        case .tmux: L10n.Setup.itemTmux
        case .gateway: L10n.Setup.itemGateway
        case .embedder: L10n.Setup.itemEmbedder
        }
    }

    func roleTitle(_ role: ExternalRole) -> String {
        switch role {
        case .notes: L10n.Setup.roleNotes
        case .liked: L10n.Setup.roleLiked
        case .rss: L10n.Setup.roleRss
        }
    }

    func originalPath(for role: ExternalRole) -> String? {
        plan?.manifest.external.first { $0.role == role }?.originalPath
    }

    func destination(for role: ExternalRole) -> URL? {
        decisions.first { $0.role == role }?.destination
    }

    func policy(for role: ExternalRole) -> ExternalConflictPolicy {
        decisions.first { $0.role == role }?.policy ?? .skipExisting
    }

    func conflict(for role: ExternalRole) -> ExternalConflict? {
        conflicts.first { $0.role == role }
    }

    func setDestination(_ url: URL, for role: ExternalRole) {
        guard let index = decisions.firstIndex(where: { $0.role == role }) else { return }
        decisions[index].destination = url
    }

    func setPolicy(_ policy: ExternalConflictPolicy, for role: ExternalRole) {
        guard let index = decisions.firstIndex(where: { $0.role == role }) else { return }
        decisions[index].policy = policy
    }

    func chooseArchive(_ url: URL) {
        if let plan {
            ConfigArchive.discard(plan)
            self.plan = nil
            decisions = []
            conflicts = []
        }
        validationToken += 1
        let token = validationToken
        validating = true
        error = nil
        let configDir = configDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let plan = try ConfigArchive.validate(archive: url, configDir: configDir)
                let decisions = ConfigArchive.defaultDecisions(plan: plan)
                let conflicts = ConfigArchive.scanConflicts(plan: plan, decisions: decisions)
                DispatchQueue.main.async {
                    guard let self, self.validationToken == token else {
                        ConfigArchive.discard(plan)
                        return
                    }
                    self.plan = plan
                    self.decisions = decisions
                    self.conflicts = conflicts
                    self.validating = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.validationToken == token else { return }
                    self.error = error.localizedDescription
                    self.validating = false
                }
            }
        }
    }

    func abortImport() {
        validationToken += 1
        if let plan {
            ConfigArchive.discard(plan)
        }
        plan = nil
        decisions = []
        conflicts = []
        error = nil
    }

    func skipImport() {
        validationToken += 1
        currentConfig = Self.loadConfig(configDir)
        step = .check
        startCheck()
    }

    func importSelectedArchive() {
        guard let plan else { return }
        validating = true
        error = nil
        let decisions = decisions
        let configDir = configDir
        var remaps: [ExternalRole: URL] = [:]
        for decision in decisions {
            let original = plan.manifest.external.first { $0.role == decision.role }?.originalPath
            if original != decision.destination.path {
                remaps[decision.role] = decision.destination
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var backup: URL?
            do {
                try ConfigArchive.validateExternalDestinations(decisions)
                if !remaps.isEmpty {
                    try ConfigArchive.rewriteConfigPaths(
                        configFile: plan.stagingDir.appendingPathComponent("config/config.yaml"),
                        remaps: remaps,
                    )
                }
                let backupURL = try ConfigArchive.applyCore(plan, configDir: configDir)
                backup = backupURL
                if plan.manifest.gatewayWheel != GatewayInstaller.bundledWheelName {
                    GatewayInstaller.invalidateStamp()
                }
                _ = try ConfigArchive.applyExternal(
                    decisions: decisions,
                    plan: plan,
                    backup: backupURL,
                )
                ConfigArchive.discard(plan)
                let config = Self.loadConfig(configDir)
                DispatchQueue.main.async {
                    self?.currentConfig = config
                    self?.plan = nil
                    self?.validating = false
                    self?.step = .check
                    self?.startCheck()
                }
            } catch {
                var rolledBack = false
                if let backup {
                    do {
                        try ConfigArchive.rollbackCore(
                            backup: backup,
                            configDir: configDir,
                            plan: plan,
                        )
                        rolledBack = true
                    } catch {
                        rolledBack = false
                    }
                }
                let message: String
                if let backup {
                    message =
                        rolledBack
                        ? L10n.Setup.importFailedRolledBack(
                            message: error.localizedDescription,
                            backup: backup.path,
                        )
                        : L10n.Setup.importFailedRollbackFailed(
                            message: error.localizedDescription,
                            backup: backup.path,
                        )
                } else {
                    message = error.localizedDescription
                }
                DispatchQueue.main.async {
                    self?.error = message
                    self?.validating = false
                }
            }
        }
    }

    func startCheck(clearError: Bool = true) {
        checking = true
        if clearError { error = nil }
        let config = currentConfig
        let configDir = configDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = SetupProbe.check(config: config, configDir: configDir)
            DispatchQueue.main.async {
                self?.items = items
                self?.checking = false
            }
        }
    }

    func nextFromCheck() {
        step = allRequiredOK ? .done : .install
    }

    func startInstall() {
        installing = true
        error = nil
        logLines = []
        append("installing \(missingRequired.map(\.id.rawValue).joined(separator: ", "))")
        SetupInstaller.install(
            items: items,
            config: currentConfig,
            venvPython: PythonScriptRunner.pythonVenvPath,
            log: { [weak self] line in
                DispatchQueue.main.async { self?.append(line) }
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.installing = false
                switch result {
                case .success:
                    self.startCheck()
                case .failure(let error):
                    self.startCheck(clearError: false)
                    self.error = error.localizedDescription
                }
            },
        )
    }

    func nextFromInstall() {
        if allRequiredOK {
            step = .done
        } else {
            startCheck()
        }
    }

    func finish() {
        onFinish()
    }

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 {
            logLines.removeFirst(logLines.count - 2000)
        }
    }

    private nonisolated static func loadConfig(_ directory: URL) -> AppConfig {
        let file = directory.appendingPathComponent("config.yaml")
        guard let data = try? Data(contentsOf: file),
            let config = try? YAMLDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }
}
