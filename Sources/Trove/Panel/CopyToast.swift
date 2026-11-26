import AppKit
import SwiftUI

/// A short confirmation after a copy: "Copied to Clipboard" in a small pill at the bottom of the
/// active screen. The panel closes on copy, so this is the only sign that the copy happened.
/// It ignores the mouse, never takes focus, and fades out after about a second.
@MainActor
final class CopyToast {
    static let visibleTime: TimeInterval = 1.1

    private let window: NSPanel
    private let effect = NSVisualEffectView()
    private let host: NSHostingView<CopyToastView>
    private var hideWork: DispatchWorkItem?

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.hidesOnDeactivate = false

        effect.blendingMode = .behindWindow
        effect.state = .active
        host = NSHostingView(rootView: CopyToastView(message: "", symbol: "", tint: .green))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        window.contentView = effect
    }

    /// Uses the panel's appearance, so the pill matches it.
    func apply(_ appearance: PanelAppearance) {
        switch appearance {
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .system: window.appearance = nil
        }
    }

    func show(_ message: String, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        hideWork?.cancel()
        host.rootView = CopyToastView(message: message, symbol: symbol, tint: tint)
        let size = host.fittingSize
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effect.material = dark ? .hudWindow : .popover
        effect.maskImage = Self.capsuleMask(height: size.height)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 96)
            window.setFrame(NSRect(origin: origin, size: size), display: false)
        }

        window.alphaValue = 0
        window.orderFrontRegardless()
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }

        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleTime, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window.alphaValue == 0 else { return }
                self.window.orderOut(nil)
            }
        }
    }

    /// A stretchable capsule: round ends, the middle stretches.
    private static func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct CopyToastView: View {
    let message: String
    var symbol = "checkmark.circle.fill"
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .fixedSize()
    }
}
