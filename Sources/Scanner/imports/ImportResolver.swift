import Foundation

struct ResolutionContext {
    let filePaths: Set<String>
    let pythonRoots: [String]
    let javaRoots: [String]
    let swiftModules: Set<String>
}

struct ImportResolution {
    let toPath: String?
    let isExternal: Bool
    let resolver: String?

    static let unresolved = ImportResolution(toPath: nil, isExternal: false, resolver: nil)
}

protocol LanguageImportResolver {
    var supportedExtensions: Set<String> { get }
    func resolve(_ record: ImportRecord, context: ResolutionContext) -> ImportResolution
}

enum ImportResolverRegistry {
    private static let resolvers: [LanguageImportResolver] = [
        PythonImportResolver(),
        JSImportResolver(),
        JavaImportResolver(),
        SwiftImportResolver(),
    ]

    private static let byExtension: [String: LanguageImportResolver] = {
        var map: [String: LanguageImportResolver] = [:]
        for resolver in resolvers {
            for ext in resolver.supportedExtensions {
                map[ext] = resolver
            }
        }
        return map
    }()

    static func resolve(_ record: ImportRecord, context: ResolutionContext) -> ImportRecord {
        let ext = (record.fromPath as NSString).pathExtension.lowercased()
        guard let resolver = byExtension[ext] else { return record }
        return record.resolved(resolver.resolve(record, context: context))
    }

    static func resolveAll(_ records: [ImportRecord], context: ResolutionContext) -> [ImportRecord] {
        records.map { resolve($0, context: context) }
    }
}

enum ImportPath {
    /// Collapse `.` / `..`; returns nil when the path escapes the project root.
    static func normalize(_ path: String) -> String? {
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default:
                parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    static func dirname(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    static func join(_ base: String, _ relative: String) -> String {
        base.isEmpty ? relative : base + "/" + relative
    }

    static func hasExtension(_ path: String) -> Bool {
        !(path as NSString).pathExtension.isEmpty
    }
}

enum ResolutionContextBuilder {
    private static let javaRootCandidates = [
        "src/main/java", "src/test/java", "src/main/kotlin", "src/test/kotlin",
    ]

    static func make(
        projectPath: String,
        filePaths: Set<String>,
        manifestDirs: Set<String>
    ) -> ResolutionContext {
        var pythonRoots = [""]
        for dir in manifestDirs.sorted() {
            pythonRoots.append(dir)
            let src = ImportPath.join(dir, "src")
            if filePaths.contains(where: { $0.hasPrefix(src + "/") }) {
                pythonRoots.append(src)
            }
        }
        if pythonRoots.count == 1, filePaths.contains(where: { $0.hasPrefix("src/") }) {
            pythonRoots.append("src")
        }

        var javaRoots = rootCandidates(javaRootCandidates, in: filePaths)
        if javaRoots.isEmpty { javaRoots.append("") }

        return ResolutionContext(
            filePaths: filePaths,
            pythonRoots: unique(pythonRoots),
            javaRoots: unique(javaRoots),
            swiftModules: swiftModules(projectPath: projectPath, filePaths: filePaths),
        )
    }

    /// Find source roots at any depth: `module/src/main/java` is as valid as `src/main/java`.
    private static func rootCandidates(_ candidates: [String], in filePaths: Set<String>) -> [String] {
        var roots: Set<String> = []
        for candidate in candidates {
            let marker = candidate + "/"
            for path in filePaths {
                if path.hasPrefix(marker) {
                    roots.insert(candidate)
                } else if let range = path.range(of: "/" + marker) {
                    roots.insert(String(path[..<range.upperBound].dropLast()))
                }
            }
        }
        return roots.sorted()
    }

    private static func swiftModules(projectPath: String, filePaths: Set<String>) -> Set<String> {
        var modules: Set<String> = []
        let manifest = (projectPath as NSString).appendingPathComponent("Package.swift")
        if let text = try? String(contentsOfFile: manifest, encoding: .utf8) {
            let pattern = #"\.(?:executable)?[Tt]arget\(\s*name:\s*"([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = text as NSString
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    if match.range(at: 1).location != NSNotFound {
                        modules.insert(ns.substring(with: match.range(at: 1)))
                    }
                }
            }
        }
        for path in filePaths where path.hasPrefix("Sources/") {
            let rest = path.dropFirst("Sources/".count)
            if let first = rest.split(separator: "/").first {
                modules.insert(String(first))
            }
        }
        return modules
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
