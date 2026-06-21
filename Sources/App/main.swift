import AppKit

// 检测 CLI 模式：如果有命令行参数（不是普通启动），进入 CLI 路由
if CommandLine.arguments.count > 1 {
    // CLI 模式：跳过程序路径和子命令名
    // 初始化必要的基础设施
    try? ConfigManager.shared.load()
    try? AppDatabase.shared.setup()

    RSSCommand.main([String](CommandLine.arguments.dropFirst(2)))
} else {
    // 正常 GUI 启动
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
