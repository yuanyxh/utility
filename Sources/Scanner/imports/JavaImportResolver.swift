import Foundation

struct JavaImportResolver: LanguageImportResolver {
    let supportedExtensions: Set<String> = ["java", "kt"]

    func resolve(_ record: ImportRecord, context: ResolutionContext) -> ImportResolution {
        var raw = record.rawTarget
        let isWildcard = raw.hasSuffix(".*")
        if isWildcard { raw = String(raw.dropLast(2)) }

        let segments = raw.split(separator: ".").map(String.init)
        for count in stride(from: segments.count, through: 1, by: -1) {
            let module = segments.prefix(count).joined(separator: "/")
            for root in context.javaRoots {
                let candidate = ImportPath.join(root, module)
                for ext in ["java", "kt"] {
                    let path = candidate + "." + ext
                    if context.filePaths.contains(path) {
                        return ImportResolution(
                            toPath: path, isExternal: false, resolver: "java-class",
                        )
                    }
                }
            }
        }

        let first = segments.first ?? raw
        let inProject = context.javaRoots.contains { root in
            let prefix = ImportPath.join(root, first)
            return context.filePaths.contains(where: { $0.hasPrefix(prefix + "/") })
        }
        return ImportResolution(
            toPath: nil,
            isExternal: !inProject,
            resolver: "java-class",
        )
    }
}
