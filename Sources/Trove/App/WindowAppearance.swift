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
