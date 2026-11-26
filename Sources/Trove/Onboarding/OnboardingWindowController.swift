import AppKit
import SwiftUI

/// First-launch window. Closing it before the end quits the app,
/// because Clipboard records nothing until a storage location is chosen.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    func apply(_ appearance: PanelAppearance, animated: Bool) {
        window.apply(appearance, animated: animated)
    }
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init()
        window.contentView = NSHostingView(rootView: OnboardingView(app: app, settings: app.settings))
        window.delegate = self
        window.center()
        window.apply(app.settings.panelAppearance, animated: false)
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if app?.settings.onboardingCompleted != true {
            NSApp.terminate(nil)
        }
    }
}
