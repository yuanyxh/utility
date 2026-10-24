import Foundation

struct SwiftImportResolver: LanguageImportResolver {
    let supportedExtensions: Set<String> = ["swift"]

    func resolve(_ record: ImportRecord, context: ResolutionContext) -> ImportResolution {
        let module = record.rawTarget.split(separator: ".").first.map(String.init)
            ?? record.rawTarget
        if context.swiftModules.contains(module) {
            return ImportResolution(toPath: nil, isExternal: false, resolver: "swift-module")
        }
        return ImportResolution(toPath: nil, isExternal: true, resolver: "swift-module")
    }
}
