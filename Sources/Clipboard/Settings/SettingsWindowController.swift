import AppKit
import SwiftUI

/// Esc closes Settings, when nothing inside used it first (the shortcut recorder and sheets do).
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// A window with a transparent title bar over a translucent background. The tab bar sits in
/// the title bar area, centred, next to the window buttons.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    /// Called when the window closes (close button, ⌘W).
    var onClose: (() -> Void)?

    init(app: AppModel) {
        window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        let host = NSHostingView(rootView: SettingsView(app: app, settings: app.settings))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        window.contentView = background
        window.center()
        window.apply(app.settings.panelAppearance, animated: false)
        super.init()
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    var isVisible: Bool { window.isVisible }

    func apply(_ appearance: PanelAppearance, animated: Bool) {
        window.apply(appearance, animated: animated)
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
