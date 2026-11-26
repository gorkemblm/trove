import AppKit
import Carbon.HIToolbox

/// Pastes into the app in front by sending ⌘V, after the clipboard holds the chosen item.
///
/// The panel never takes focus from that app (it is a non-activating panel), so ⌘V goes to the
/// place the user was typing in. Sending key events needs the user's permission
/// (Privacy & Security › Accessibility); without it Clipboard only copies.
@MainActor
enum Paster {
    /// True when macOS allows this app to send key events.
    static var isAllowed: Bool { CGPreflightPostEventAccess() }

    /// Shows the macOS permission prompt (once; later it only answers). Returns the state.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestPostEventAccess() }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sends ⌘V a moment after the panel closed, so the previous window has the keyboard again.
    static func pasteSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            MainActor.assumeIsolated { sendCommandV() }
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = keyCode(for: "v")
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key that types `character` in the current keyboard layout. "V" is not in the same
    /// place everywhere (Turkish F, Dvorak); the ANSI position is the fallback.
    static func keyCode(for character: String) -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return fallback }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &characters)
                if status == noErr, length == 1, String(utf16CodeUnits: characters, count: 1) == character {
                    return CGKeyCode(code)
                }
            }
            return fallback
        }
    }
}
