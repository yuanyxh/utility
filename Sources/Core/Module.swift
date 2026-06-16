import Cocoa

/// 应用模块协议
/// 所有功能模块需遵循此协议，通过 ModuleRegistry 统一管理
public protocol AppModule {
    /// 模块名称
    var name: String { get }

    /// 模块初始化（配置加载后调用）
    func setup() throws

    /// 注册热键
    func registerHotkeys(using manager: HotkeyManager) throws

    /// 配置重载通知
    func onConfigReload() throws

    /// 模块清理
    func teardown()
}

/// 后台服务模块（远期预留）
public protocol BackgroundService: AppModule {
    /// 执行间隔（秒）
    var interval: TimeInterval { get }
    /// 执行服务逻辑
    func execute() async throws
}

// MARK: - Module Registry

/// 模块注册中心
public final class ModuleRegistry {
    public static let shared = ModuleRegistry()
    private var modules: [String: AppModule] = [:]

    private init() {}

    public func register(_ module: AppModule) {
        modules[module.name] = module
        print("[Module] Registered: \(module.name)")
    }

    public func setupAll() {
        for (_, module) in modules {
            do {
                try module.setup()
            } catch {
                print("[Module] Setup failed: \(module.name): \(error)")
            }
        }
    }

    public func registerAllHotkeys() {
        for (_, module) in modules {
            do {
                try module.registerHotkeys(using: .shared)
            } catch {
                print("[Module] Hotkey registration failed: \(module.name): \(error)")
            }
        }
    }

    public func unregister(_ name: String) {
        modules[name]?.teardown()
        modules.removeValue(forKey: name)
    }
}
