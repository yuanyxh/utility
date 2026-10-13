import Foundation

/// `MCPScripts/` resource location (single source of truth).
///
/// Python scripts and prompt templates are both distributed under `MCPScripts/` (`Package.swift`'s
/// `.copy("MCPScripts")` preserves the directory structure); at runtime they may land in two locations:
///
/// 1. **Inside the bundle**: `Bundle.module.resourceURL/MCPScripts/…` (in `swift build` output and inside the app)
/// 2. **Dev directory**: SPM places the resource bundle at `.build/<triple>/<pkg>_<pkg>.bundle/Contents/Resources/`,
///    going up two levels from there is the repo root, so `MCPScripts/…` hits the source directory directly
///
/// This derivation originally existed only in `PythonScriptRunner.findScript(named:)`. If prompt reading copied it again,
/// the two would eventually drift — changing the bundle layout in only one place leaves the other **silently failing to find the file** (scripts manifest as an unavailable feature,
/// prompts manifest as quietly falling back to built-in text), hence consolidated here.
enum MCPScriptsResources {
    /// Candidate root directories (by priority). Resolved lazily once and cached: the resource layout does not change within the process lifetime,
    /// while this API gets called many times by prompt reading per feature × language.
    private static let roots: [String] = {
        guard let resourceURL = Bundle.module.resourceURL else {
            debugLog("[Resources] No bundle resource URL")
            return []
        }
        let bundled = resourceURL.appendingPathComponent("MCPScripts").path
        let devBase = resourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dev = devBase.appendingPathComponent("MCPScripts").path
        return [bundled, dev]
    }()

    /// Path relative to `MCPScripts/` → absolute path; returns nil if neither location exists.
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
}
