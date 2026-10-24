import Foundation

struct PythonImportResolver: LanguageImportResolver {
    let supportedExtensions: Set<String> = ["py"]

    func resolve(_ record: ImportRecord, context: ResolutionContext) -> ImportResolution {
        let raw = record.rawTarget
        if raw.hasPrefix(".") {
            return resolveRelative(raw, fromPath: record.fromPath, context: context)
        }
        return resolveAbsolute(raw, context: context)
    }

    private func resolveRelative(
        _ raw: String, fromPath: String, context: ResolutionContext
    ) -> ImportResolution {
        let dots = raw.prefix(while: { $0 == "." }).count
        let module = String(raw.dropFirst(dots)).replacingOccurrences(of: ".", with: "/")
        var base = ImportPath.dirname(fromPath)
        guard dots > 0 else { return .unresolved }
        for _ in 1 ..< dots {
            guard !base.isEmpty else { return .unresolved }
            base = ImportPath.dirname(base)
        }
        let candidate = ImportPath.join(base, module)
        if let path = findModule(candidate, context: context) {
            return ImportResolution(toPath: path, isExternal: false, resolver: "python-module")
        }
        // `from . import name` may reference an attribute defined in the package.
        if dots == 1, !module.contains("/") {
            let packageInit = ImportPath.join(base, "__init__.py")
            if context.filePaths.contains(packageInit) {
                return ImportResolution(
                    toPath: packageInit, isExternal: false, resolver: "python-module",
                )
            }
        }
        return ImportResolution(toPath: nil, isExternal: false, resolver: "python-module")
    }

    private func resolveAbsolute(_ raw: String, context: ResolutionContext) -> ImportResolution {
        let module = raw.replacingOccurrences(of: ".", with: "/")
        for root in context.pythonRoots {
            let candidate = ImportPath.join(root, module)
            if let path = findModule(candidate, context: context) {
                return ImportResolution(toPath: path, isExternal: false, resolver: "python-module")
            }
        }
        let first = raw.split(separator: ".").first.map(String.init) ?? raw
        let inProject = context.pythonRoots.contains { root in
            let prefix = ImportPath.join(root, first)
            return context.filePaths.contains(where: {
                $0 == prefix + ".py" || $0.hasPrefix(prefix + "/")
            })
        }
        return ImportResolution(
            toPath: nil,
            isExternal: !inProject,
            resolver: "python-module",
        )
    }

    private func findModule(_ candidate: String, context: ResolutionContext) -> String? {
        // Python prefers a package directory over a same-named module file.
        if context.filePaths.contains(candidate + "/__init__.py") {
            return candidate + "/__init__.py"
        }
        if context.filePaths.contains(candidate + ".py") { return candidate + ".py" }
        // `from . import x`: the module part is empty, the package itself is the target.
        if candidate.isEmpty, context.filePaths.contains("__init__.py") {
            return "__init__.py"
        }
        return nil
    }
}
