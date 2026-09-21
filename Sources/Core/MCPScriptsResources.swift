import Foundation

/// `MCPScripts/` 资源定位（唯一来源）。
///
/// Python 脚本与提示词模板都随包分发在 `MCPScripts/` 下（`Package.swift` 的
/// `.copy("MCPScripts")` 保留目录结构），执行期可能落在两个位置：
///
/// 1. **打包内**：`Bundle.module.resourceURL/MCPScripts/…`（`swift build` 产物与 app 内）
/// 2. **开发目录**：SPM 把资源 bundle 放在 `.build/<triple>/<pkg>_<pkg>.bundle/Contents/Resources/`，
///    自其上溯两级即仓库根，故 `MCPScripts/…` 直接命中源码目录
///
/// 这段推导原先只存在于 `PythonScriptRunner.findScript(named:)`。提示词读取再抄一份的话，
/// 两者迟早漂移——改了 bundle 布局只改一处，另一处**静默读不到文件**（脚本表现为功能不可用，
/// 提示词表现为悄悄回退成内置文案），故收束至此。
enum MCPScriptsResources {
    /// 候选根目录（按优先级）。惰性解析一次并缓存：资源布局在进程生命周期内不变，
    /// 而本 API 会被提示词读取按 feature × 语言调用多次。
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

    /// 相对 `MCPScripts/` 的路径 → 绝对路径；两处都不存在返回 nil。
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
