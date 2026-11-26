import AppKit
import SwiftUI

/// "How Trove Works": the demos of onboarding, opened again from the menu bar menu, ⌘K or Settings.
@MainActor
final class TourWindowController {
    private let window: NSWindow

    init(appearance: PanelAppearance) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 640, height: 560)),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = L("How Trove Works")
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        let host = NSHostingView(rootView: TourView())
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        window.contentView = background
        window.apply(appearance, animated: false)
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct TourView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How Trove Works").font(.system(size: 22, weight: .bold))
            Text("Eight short demos. ← → move between them.").foregroundStyle(.secondary)
            DemoTour()
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(width: 640, height: 560, alignment: .topLeading)
    }
}
