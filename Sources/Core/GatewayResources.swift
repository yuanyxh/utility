import Foundation

/// `Gateway/` resource location — the single source of truth for prompts, the
/// wheel installed on first launch, and the requirements list.
///
/// Candidates by priority:
/// 1. Bundle: `<bundle>/Contents/Resources/Gateway/…` (packaged app and `swift build` output)
/// 2. Source tree: `Sources/Gateway/…` (written by the packaging script, gitignored)
/// 3. Sibling checkout: `../agent-gateway/src/agent_gateway/…` (development without installing)
///
/// The repo root is found by walking up from the resource URL until a directory
/// holding `Package.swift` shows up: hardcoding the depth breaks whenever
/// SwiftPM changes its build layout again.
enum GatewayResources {
    /// Repo root, or nil when the resource bundle sits outside a checkout (installed app).
    private static let repoRoot: String? = {
        guard let resourceURL = Bundle.module.resourceURL else {
            debugLog("[Gateway] No bundle resource URL")
            return nil
        }
        var dir = resourceURL
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    private static let roots: [String] = {
        guard let resourceURL = Bundle.module.resourceURL else { return [] }
        var candidates = [resourceURL.appendingPathComponent("Gateway").path]
        if let repoRoot {
            candidates.append((repoRoot as NSString).appendingPathComponent("Sources/Gateway"))
            candidates.append(
                (repoRoot as NSString).appendingPathComponent("../agent-gateway/src/agent_gateway"),
            )
        }
        return candidates
    }()

    /// Path relative to the resource root; nil when no candidate contains it.
    static func path(relative relativePath: String) -> String? {
        let fm = FileManager.default
        for root in roots {
            let candidate = (root as NSString).appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Directory holding the wheel, requirements list and prompts.
    static var root: String? {
        roots.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Wheel shipped inside the app, when the packaging step included one.
    static func bundledWheel() -> String? {
        guard let root else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        guard let name = files.first(where: { $0.hasSuffix(".whl") }) else { return nil }
        return (root as NSString).appendingPathComponent(name)
    }

    /// `src/` of the sibling checkout, used as `PYTHONPATH` while developing without installing.
    static func developmentSourceRoot() -> String? {
        guard let repoRoot else { return nil }
        let src = (repoRoot as NSString).appendingPathComponent("../agent-gateway/src")
        let packageDir = (src as NSString).appendingPathComponent("agent_gateway")
        return FileManager.default.fileExists(atPath: packageDir) ? src : nil
    }
}
