import Foundation
import GRDB

/// How an import statement appears in source.
enum ImportKind: String, CaseIterable {
    case staticImport = "static"
    case require
    case exportFrom = "export_from"
    case dynamicImport = "dynamic"
}

/// Lightweight DTO for AST JSON. Kept separate from `ImportRecord` so that
/// `PersistableRecord` fields never take part in decoding external output.
struct RawImport: Decodable {
    let rawTarget: String
    let kind: String
    let line: Int?

    enum CodingKeys: String, CodingKey {
        case rawTarget = "raw_target"
        case kind, line
    }
}

/// One file-level import edge. `toPath` / `isExternal` / `resolver` are filled
/// by the resolution pass; extraction only fills the first four fields.
struct ImportRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "imports"

    var id: Int64?
    var fromPath: String
    var rawTarget: String
    var toPath: String?
    var isExternal: Bool
    var kind: String
    var line: Int?
    var confidence: Double
    var resolver: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fromPath = "from_path"
        case rawTarget = "raw_target"
        case toPath = "to_path"
        case isExternal = "is_external"
        case kind, line, confidence, resolver
    }

    init(
        fromPath: String,
        rawTarget: String,
        kind: ImportKind,
        line: Int? = nil,
        confidence: Double,
        toPath: String? = nil,
        isExternal: Bool = false,
        resolver: String? = nil
    ) {
        self.fromPath = fromPath
        self.rawTarget = rawTarget
        self.kind = kind.rawValue
        self.line = line
        self.confidence = confidence
        self.toPath = toPath
        self.isExternal = isExternal
        self.resolver = resolver
    }

    func resolved(_ resolution: ImportResolution) -> ImportRecord {
        var copy = self
        copy.toPath = resolution.toPath
        copy.isExternal = resolution.isExternal
        copy.resolver = resolution.resolver
        return copy
    }
}

struct ASTFileResult {
    let symbols: [SymbolRecord]
    let imports: [ImportRecord]
}
