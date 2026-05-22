import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var keepAlive: AppDelegate!
    private var menuBarController: MenuBarController!

    /// Explicit entry point. The default `@main` synthesis for
    /// NSApplicationDelegate-conforming types calls `NSApplicationMain`, which
    /// only wires up the delegate when a Main nib/storyboard exists. We don't
    /// ship one (LSUIElement app), so we attach the delegate ourselves.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        keepAlive = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
        menuBarController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
    }
}
