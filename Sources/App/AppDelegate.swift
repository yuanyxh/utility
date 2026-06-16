import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Utility] Starting up...")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[Utility] Shutting down...")
    }
}
