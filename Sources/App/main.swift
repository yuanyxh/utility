import AppKit

// 检测 CLI 模式：如果有命令行参数（不是普通启动），进入 CLI 路由
if CommandLine.arguments.count > 1 {
    // CLI 模式：初始化必要的基础设施
    try? ConfigManager.shared.load()
    try? AppDatabase.shared.setup()

    UtilityCLI.main()
} else {
    // 正常 GUI 启动
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
