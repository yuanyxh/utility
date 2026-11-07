import Foundation

/// User data categories selectable in the export sheet.
enum ArchiveScope: String, CaseIterable, Codable, Sendable {
    case config
    case memory
    case knowledge
    case local
    case terminal
    case notes
    case usage
}

/// External directories that live outside `~/.config/utility`.
enum ExternalRole: String, Codable, Sendable {
    case notes
    case liked
    case rss
}

struct ArchiveOptions: Sendable {
    var scopes: Set<ArchiveScope>
    var includesSecrets: Bool

    init(scopes: Set<ArchiveScope>, includesSecrets: Bool = false) {
        self.scopes = scopes
        self.includesSecrets = includesSecrets
    }
}

struct ArchiveFile: Codable, Sendable, Equatable {
    var path: String
    var sha256: String
    var bytes: Int
}

struct ExternalDir: Codable, Sendable, Equatable {
    var role: ExternalRole
    var originalPath: String
    var archivePath: String
    var fileCount: Int
    var bytes: Int
}

struct ArchiveManifest: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var appVersion: String
    var gatewayWheel: String?
    var createdAt: String
    var includesSecrets: Bool
    var scope: [ArchiveScope]
    var files: [ArchiveFile]
    var external: [ExternalDir]
    var sourcePaths: [String: String]
}

enum ArchiveMemberKind: Sendable {
    case copy
    case directory
    case sqliteBackup
}

struct ArchiveMember: Sendable {
    var archivePath: String
    var sourceURL: URL
    var kind: ArchiveMemberKind
}

struct ExternalPath: Sendable, Equatable {
    var role: ExternalRole
    var root: URL
}

struct ArchiveImportPlan: Sendable {
    var stagingDir: URL
    var manifest: ArchiveManifest
    var files: [ArchiveFile]
}

enum ExternalConflictPolicy: String, Sendable {
    case skipExisting
    case overwrite
}

struct ExternalRestoreDecision: Sendable {
    var role: ExternalRole
    var destination: URL
    var policy: ExternalConflictPolicy
}

struct ExternalConflict: Sendable, Equatable {
    var role: ExternalRole
    var destination: URL
    var existingCount: Int
    var totalCount: Int
}

struct ExternalApplyResult: Sendable, Equatable {
    var copied = 0
    var skipped = 0
    var overwritten = 0
}

enum ArchiveError: LocalizedError, Equatable {
    case invalidManifest(String)
    case checksumMismatch(String)
    case pathTraversal(String)
    case schemaMismatch(String, [String])
    case sizeLimit(Int)
    case fileLimit(Int)
    case backupFailed(String)
    case writeFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail):
            "Invalid archive manifest: \(detail)"
        case .checksumMismatch(let path):
            "Checksum mismatch: \(path)"
        case .pathTraversal(let path):
            "Unsafe path in archive: \(path)"
        case .schemaMismatch(let path, let tables):
            "Database schema mismatch in \(path): \(tables.joined(separator: ", "))"
        case .sizeLimit(let bytes):
            "Archive exceeds the \(bytes)-byte limit"
        case .fileLimit(let count):
            "Archive exceeds the \(count)-file limit"
        case .backupFailed(let detail):
            "Backup failed: \(detail)"
        case .writeFailed(let detail):
            "Write failed: \(detail)"
        case .timeout(let detail):
            "Timed out: \(detail)"
        }
    }
}
