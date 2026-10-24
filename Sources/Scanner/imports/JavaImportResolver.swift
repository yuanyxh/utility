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

        // Only the exact package directory counts as project-internal; a shared
        // top-level prefix (`com`, `org`) is not enough.
        let packageSegments = isWildcard ? segments : Array(segments.dropLast())
        let packageDir = packageSegments.joined(separator: "/")
        let inProject = !packageSegments.isEmpty && context.javaRoots.contains { root in
            let dir = ImportPath.join(root, packageDir)
            return context.filePaths.contains(where: { $0.hasPrefix(dir + "/") })
        }
        return ImportResolution(
            toPath: nil,
            isExternal: !inProject,
            resolver: "java-class",
        )
    }
}
