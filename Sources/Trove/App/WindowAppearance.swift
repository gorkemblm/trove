import AppKit
import QuartzCore

extension NSWindow {
    /// Sets the app appearance. With `animated`, the old and new colours cross-fade for a
    /// quarter second, so the switch is smooth instead of a jump.
    func apply(_ appearance: PanelAppearance, animated: Bool) {
        let target = appearance.nsAppearance
        guard animated, isVisible, let content = contentView else {
            self.appearance = target
            return
        }
        content.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        content.layer?.add(fade, forKey: "appearance")
        self.appearance = target
    }
}

extension NSWindow {
    /// Opens the window in front of every app, with the keyboard.
    ///
    /// Since macOS 14, `NSApp.activate()` is only a request. The panel does not activate Trove,
    /// so while another app is active the request can be refused, and `makeKeyAndOrderFront`
    /// alone then puts the window behind that app's windows. `orderFrontRegardless` shows it
    /// in front in any case; the first click gives it the keyboard if activation was refused.
    func showInFront() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}
