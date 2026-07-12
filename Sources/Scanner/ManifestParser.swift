import Foundation

/// Detects project manifests and extracts package information.
enum ManifestParser {
    struct ManifestInfo {
        let type: String // spm / npm / pip / gradle
        let packages: [PackageRecord]
    }

    /// Detect and parse all manifests in the given directory.
    static func parseAll(in directory: String) -> [ManifestInfo] {
        var results: [ManifestInfo] = []
        let fm = FileManager.default

        // Package.swift
        let spmPath = (directory as NSString).appendingPathComponent("Package.swift")
        if fm.fileExists(atPath: spmPath),
           let content = try? String(contentsOfFile: spmPath)
        {
            results.append(parseSPM(content))
        }

        // package.json
        let npmPath = (directory as NSString).appendingPathComponent("package.json")
        if fm.fileExists(atPath: npmPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: npmPath)),
           let info = parseNPM(data)
        {
            results.append(info)
        }

        // pyproject.toml
        let pyPath = (directory as NSString).appendingPathComponent("pyproject.toml")
        if fm.fileExists(atPath: pyPath),
           let content = try? String(contentsOfFile: pyPath)
        {
            results.append(parsePyProject(content))
        }

        // Podfile
        let podPath = (directory as NSString).appendingPathComponent("Podfile")
        if fm.fileExists(atPath: podPath) {
            results.append(ManifestInfo(type: "cocoapods", packages: []))
        }

        return results
    }

    // MARK: - SPM

    private static func parseSPM(_ content: String) -> ManifestInfo {
        var packages: [PackageRecord] = []
        // Match: .package(url: "...", from: "...")
        //      .package(url: "...", exact: ...)
        //      .package(path: "...")
        let pattern = #/\.package\(.*?(?:url:|path:)\s*"([^"]+)".*?(?:(?:from|exact|revision|branch):\s*"([^"]+)")?\)/#
        for match in content.matches(of: pattern) {
            let urlOrPath = String(match.1)
            let version = match.2.map(String.init)

            // Extract name from URL: https://github.com/owner/name.git → name
            let name: String
            if urlOrPath.hasPrefix("http") || urlOrPath.hasPrefix("git@") {
                let parts = urlOrPath.split(separator: "/")
                name = parts.last?.replacingOccurrences(of: ".git", with: "").replacingOccurrences(of: "\"", with: "") ?? urlOrPath
            } else {
                name = (urlOrPath as NSString).lastPathComponent
            }

            packages.append(PackageRecord(
                name: name,
                version: version,
                type: "spm",
                description: nil,
                sourceUrl: urlOrPath.hasPrefix("http") ? urlOrPath : nil
            ))
        }
        return ManifestInfo(type: "spm", packages: packages)
    }

    // MARK: - npm

    private static func parseNPM(_ data: Data) -> ManifestInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var packages: [PackageRecord] = []

        // dependencies
        if let deps = json["dependencies"] as? [String: String] {
            for (name, version) in deps {
                packages.append(PackageRecord(name: name, version: version, type: "npm"))
            }
        }
        // devDependencies
        if let deps = json["devDependencies"] as? [String: String] {
            for (name, version) in deps {
                packages.append(PackageRecord(name: name, version: version, type: "npm",
                                              description: "dev"))
            }
        }

        return ManifestInfo(type: "npm", packages: packages)
    }

    // MARK: - pyproject.toml (basic)

    private static func parsePyProject(_ content: String) -> ManifestInfo {
        var packages: [PackageRecord] = []
        var inDeps = false
        var inDevDeps = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "[project]" {
                inDeps = false
                continue
            }
            if trimmed.hasPrefix("dependencies =") || trimmed == "dependencies = [" {
                inDeps = true
                continue
            }
            if trimmed.hasPrefix("[project.optional-dependencies") {
                inDevDeps = true
                continue
            }
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                inDeps = false
                inDevDeps = false
                continue
            }

            if inDeps || inDevDeps {
                // Match: "package>=version" or "package==version" or "package"
                let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\","))
                if !stripped.isEmpty, !stripped.hasPrefix("#") {
                    let parts = stripped.split(whereSeparator: { $0 == ">" || $0 == "=" || $0 == "~" || $0 == "<" || $0 == "!" })
                    let name = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
                    let version = parts.count > 1
                        ? parts.dropFirst().joined(separator: ".").trimmingCharacters(in: .whitespaces)
                        : nil
                    if !name.isEmpty {
                        packages.append(PackageRecord(
                            name: name, version: version, type: "pip",
                            description: inDevDeps ? "dev" : nil
                        ))
                    }
                }
            }
        }

        return ManifestInfo(type: "pip", packages: packages)
    }
}
