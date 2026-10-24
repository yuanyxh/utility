import Foundation

struct JSImportResolver: LanguageImportResolver {
    let supportedExtensions: Set<String> = ["js", "ts", "jsx", "tsx", "mjs", "cjs", "vue"]

    private let resolutionExtensions = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".d.ts"]

    func resolve(_ record: ImportRecord, context: ResolutionContext) -> ImportResolution {
        let raw = record.rawTarget
        guard raw.hasPrefix("./") || raw.hasPrefix("../") else {
            return ImportResolution(toPath: nil, isExternal: true, resolver: "js-path")
        }
        let base = ImportPath.dirname(record.fromPath)
        guard let normalized = ImportPath.normalize(ImportPath.join(base, raw)) else {
            return ImportResolution(toPath: nil, isExternal: false, resolver: "js-path")
        }
        if let path = find(normalized, context: context) {
            return ImportResolution(toPath: path, isExternal: false, resolver: "js-path")
        }
        return ImportResolution(toPath: nil, isExternal: false, resolver: "js-path")
    }

    private func find(_ candidate: String, context: ResolutionContext) -> String? {
        if ImportPath.hasExtension(candidate), context.filePaths.contains(candidate) {
            return candidate
        }
        for ext in resolutionExtensions {
            if context.filePaths.contains(candidate + ext) { return candidate + ext }
        }
        for ext in resolutionExtensions {
            let index = candidate + "/index" + ext
            if context.filePaths.contains(index) { return index }
        }
        return nil
    }
}
