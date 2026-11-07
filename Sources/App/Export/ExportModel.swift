import Foundation
import SwiftUI

/// Backs the export sheet: scope selection, size estimates and background archiving.
@MainActor
final class ExportModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case done(URL)
        case failed(String)
    }

    @Published var selection: Set<ArchiveScope> = []
    @Published var includesSecrets = false
    @Published private(set) var status: Status = .idle
    @Published private(set) var availableScopes: [ArchiveScope] = []
    @Published private(set) var estimatedBytes: [ArchiveScope: Int] = [:]
    @Published private(set) var logLines: [String] = []

    private let config: AppConfig
    private let configDir: URL
    private var prepared = false

    init(config: AppConfig = ConfigManager.shared.config, configDir: URL = AppPaths.configDir) {
        self.config = config
        self.configDir = configDir
    }

    var isRunning: Bool {
        status == .running
    }

    var canExport: Bool {
        prepared && !selection.isEmpty && !isRunning
    }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        availableScopes = ArchiveScope.available(in: config, configDir: configDir)
        selection = ArchiveScope.defaultSelection(in: config, configDir: configDir)
        estimateSizes()
    }

    func title(for scope: ArchiveScope) -> String {
        switch scope {
        case .config: L10n.Export.scopeConfig
        case .memory: L10n.Export.scopeMemory
        case .knowledge: L10n.Export.scopeKnowledge
        case .local: L10n.Export.scopeLocal
        case .terminal: L10n.Export.scopeTerminal
        case .notes: L10n.Export.scopeNotes
        case .usage: L10n.Export.scopeUsage
        }
    }

    func sizeText(for scope: ArchiveScope) -> String? {
        guard let bytes = estimatedBytes[scope] else { return nil }
        guard bytes > 0 else { return L10n.Export.sizeUnknown }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func export(to destination: URL) {
        guard canExport else { return }
        status = .running
        logLines = []
        append("export -> \(destination.path)")

        let options = ArchiveOptions(scopes: selection, includesSecrets: includesSecrets)
        let config = config
        let configDir = configDir
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let manifest = try ConfigArchive.export(
                    options: options,
                    config: config,
                    configDir: configDir,
                    appVersion: appVersion,
                    gatewayWheel: GatewayInstaller.bundledWheelName,
                    destination: destination,
                    log: { line in
                        DispatchQueue.main.async { self?.append(line) }
                    },
                )
                DispatchQueue.main.async {
                    self?.append("files: \(manifest.files.count)")
                    self?.status = .done(destination)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.append(error.localizedDescription)
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func estimateSizes() {
        let scopes = availableScopes
        let config = config
        let configDir = configDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var sizes: [ArchiveScope: Int] = [:]
            for scope in scopes {
                sizes[scope] = Self.estimate(scope, config: config, configDir: configDir)
            }
            DispatchQueue.main.async {
                self?.estimatedBytes = sizes
            }
        }
    }

    private nonisolated static func estimate(
        _ scope: ArchiveScope,
        config: AppConfig,
        configDir: URL,
    ) -> Int {
        if scope == .notes {
            return ArchiveScope.resolveExternalDirs(config: config, configDir: configDir)
                .reduce(0) { $0 + ArchiveExternal.scan(root: $1.root).bytes }
        }
        return scope.members(configDir: configDir).reduce(0) {
            $0 + size(of: $1.sourceURL)
        }
    }

    private nonisolated static func size(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory == true else { return values?.fileSize ?? 0 }
        var total = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true },
        )
        while let child = enumerator?.nextObject() as? URL {
            let childValues = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard childValues?.isRegularFile == true else { continue }
            total += childValues?.fileSize ?? 0
        }
        return total
    }

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 {
            logLines.removeFirst(logLines.count - 2000)
        }
    }
}
