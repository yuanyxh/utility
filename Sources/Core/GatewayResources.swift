import Foundation

/// `Gateway/` resource location — the single source of truth for prompts, the
/// wheel installed on first launch, the constraints snapshot and the entry contract.
///
/// Candidates by priority:
/// 1. Bundle: `<bundle>/Contents/Resources/Gateway/…` (packaged app and `swift build` output)
/// 2. Source tree: `Sources/Gateway/…` (written by the packaging script, gitignored)
/// 3. Sibling checkout: `../agent-gateway/src/agent_gateway/…` (development without installing)
///
/// Prompts put the sibling checkout **first**: editing a prompt must take effect without
/// repackaging, and the packaged copies only exist to serve the real app. The wheel and the
/// contracts always come from 1–2, since the source checkout has no wheel.
///
/// The repo root is found by walking up from the resource URL until a directory holding
/// `Package.swift` shows up: hardcoding the depth breaks whenever SwiftPM changes layout.
enum GatewayResources {
    /// `UTILITY_GATEWAY_USE_WHEEL=1` disables the sibling checkout, so a dev run exercises
    /// the installed wheel — the only way to test the packaged code path without packaging.
    private static let forceWheel =
        ProcessInfo.processInfo.environment["UTILITY_GATEWAY_USE_WHEEL"] == "1"

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

    /// Packaged/built resource roots (wheel, constraints, entry contract).
    private static let resourceRoots: [String] = {
        guard let resourceURL = Bundle.module.resourceURL else { return [] }
        var roots = [resourceURL.appendingPathComponent("Gateway").path]
        if let repoRoot {
            roots.append((repoRoot as NSString).appendingPathComponent("Sources/Gateway"))
        }
        return roots
    }()

    /// Sibling checkout package dir; nil when disabled or absent.
    private static let developmentPackageRoot: String? = {
        guard !forceWheel, let repoRoot else { return nil }
        let package = (repoRoot as NSString).appendingPathComponent("../agent-gateway/src/agent_gateway")
        return FileManager.default.fileExists(atPath: package) ? package : nil
    }()

    /// Log which roots are in play, once per launch — support needs to know whether a run is
    /// using the package, the sibling checkout, or both.
    static func logResolution() {
        let dev = developmentPackageRoot ?? "-"
        debugLog("[Gateway] resources: dev=\(dev) packed=\(resourceRoots.joined(separator: " | "))")
    }

    /// Path relative to a resource root; nil when no candidate contains it.
    static func path(relative relativePath: String) -> String? {
        let roots = [developmentPackageRoot].compactMap { $0 } + resourceRoots
        for root in roots {
            let candidate = (root as NSString).appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Wheel shipped inside the app, when the packaging step included one.
    static func bundledWheel() -> String? {
        for root in resourceRoots {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            if let name = files.first(where: { $0.hasSuffix(".whl") }) {
                return (root as NSString).appendingPathComponent(name)
            }
        }
        return nil
    }

    /// Dependency snapshot written at packaging time; absent = resolve ranges from the index.
    static func constraintsFile() -> String? {
        resourceRoots.lazy.compactMap {
            let candidate = ($0 as NSString).appendingPathComponent("constraints.txt")
            return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
        }.first
    }

    /// `entries.json` exported by the gateway repo; the host's `GatewayEntry` must match it.
    static func entriesFile() -> String? {
        resourceRoots.lazy.compactMap {
            let candidate = ($0 as NSString).appendingPathComponent("entries.json")
            return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
        }.first
    }

    /// `src/` of the sibling checkout, used as `PYTHONPATH` while developing without installing.
    static func developmentSourceRoot() -> String? {
        guard let developmentPackageRoot else { return nil }
        return (developmentPackageRoot as NSString).deletingLastPathComponent
    }
}
