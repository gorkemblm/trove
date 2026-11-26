import AppKit

/// Terminal apps that can open a folder. macOS has no default terminal setting, so Clipboard
/// lists the ones installed and picks one (Settings › General › Terminal).
struct TerminalApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    /// Most specific first: "Automatic" picks the first installed one, so a terminal the user
    /// installed wins over the one that comes with macOS.
    static let known: [TerminalApp] = [
        TerminalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        TerminalApp(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        TerminalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        TerminalApp(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
        TerminalApp(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        TerminalApp(bundleID: "org.alacritty", name: "Alacritty"),
        TerminalApp(bundleID: "co.zeit.hyper", name: "Hyper"),
        TerminalApp(bundleID: "org.tabby", name: "Tabby"),
        TerminalApp(bundleID: "com.apple.Terminal", name: "Terminal"),
    ]

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var installed: [TerminalApp] { known.filter { $0.url != nil } }

    /// The chosen terminal if it is still installed; otherwise the first installed one.
    static func resolve(_ bundleID: String?) -> TerminalApp? {
        let installed = installed
        if let bundleID, let chosen = installed.first(where: { $0.bundleID == bundleID }) { return chosen }
        return installed.first
    }

    /// The folder to open: a folder itself, or the folder that holds a file.
    static func folder(for path: String) -> URL {
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return url }
        return url.deletingLastPathComponent()
    }

    /// warp://action/new_tab?path=… (docs.warp.dev, URI scheme). The path is percent-encoded.
    static func warpLink(for folder: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "action"
        components.path = "/new_tab"
        components.queryItems = [URLQueryItem(name: "path", value: folder.path)]
        return components.url
    }

    /// Warp opens a folder from its own URL scheme, which needs no file access from this app.
    /// Other terminals get the folder from Launch Services; macOS may refuse that for a folder
    /// this sandboxed app has no access to, and the completion reports it.
    @MainActor
    func open(_ folder: URL, completion: @escaping @MainActor (Bool) -> Void) {
        if bundleID == "dev.warp.Warp-Stable" {
            guard let link = Self.warpLink(for: folder) else { completion(false); return }
            completion(NSWorkspace.shared.open(link))
            return
        }
        guard let app = url else { completion(false); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
}
