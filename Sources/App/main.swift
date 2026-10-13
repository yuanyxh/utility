import AppKit

// Detect CLI mode: if there are command-line arguments (not a normal launch), enter CLI routing
if CommandLine.arguments.count > 1 {
    // CLI mode: initialize the necessary infrastructure
    try? ConfigManager.shared.load()
    try? AppDatabase.shared.setup()

    UtilityCLI.main()
} else {
    // Normal GUI launch
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
