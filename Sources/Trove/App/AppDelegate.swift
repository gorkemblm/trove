import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if SNAPSHOTS
        // `make layout` only: renders the panel to PNG files and checks layout stability.
        // The shipped app is built without this code.
        if let index = CommandLine.arguments.firstIndex(of: "--demos") {
            let dir = CommandLine.arguments.dropFirst(index + 1).first ?? "demos"
            exit(DemoMaker.run(outputDirectory: URL(fileURLWithPath: dir)))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let dir = CommandLine.arguments.dropFirst(index + 1).first ?? "snapshots"
            exit(SnapshotRunner.run(outputDirectory: URL(fileURLWithPath: dir)))
        }
        #endif
        // The menu bar is never visible (LSUIElement), but its key equivalents
        // make ⌘C, ⌘V, ⌘A and ⌘Z work in text fields.
        NSApp.mainMenu = MainMenu.make(target: self)
        ExportFiles.removeAll() // Left over if the last run ended abruptly.
        app.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ExportFiles.removeAll()
    }

    /// Opening the app again (Finder, Spotlight, Dock, `open`) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        app.showPanel()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func openSettings(_ sender: Any?) {
        app.openSettings()
    }
}

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.iokoda.clipboard"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// Bug reports and ideas: the Issues page of the public releases repository.
    static let supportURL = URL(string: "https://github.com/gorkemblm/trove-releases/issues")!
}
