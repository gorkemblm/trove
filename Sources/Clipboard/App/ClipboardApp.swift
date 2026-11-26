import AppKit

/// Entry point. The app runs as an accessory: no Dock icon, no menu bar item.
@main
@MainActor
enum ClipboardApp {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
