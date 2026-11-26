import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut, registered with Carbon `RegisterEventHotKey`.
/// This API needs no Accessibility permission and works inside the sandbox.
@MainActor
final class GlobalHotKey {
    struct Combo: Equatable, Codable, Sendable {
        /// Virtual key code, for example `kVK_Space`.
        var keyCode: UInt32
        /// Carbon modifier flags, for example `optionKey`.
        var modifiers: UInt32
    }

    struct RegistrationError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            status == eventHotKeyExistsErr
                ? L("This shortcut is already in use by another app.")
                : String(localized: "The shortcut could not be registered (OSStatus \(String(status))).")
        }
    }

    private static let signature: OSType = 0x434C_4950 // "CLIP"
    /// Each shortcut has its own id. Every handler sees every hot key event, so each one
    /// acts only on its own id and passes the others on.
    private static var nextID: UInt32 = 1
    private let id: UInt32

    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        installHandler()
    }

    func register(_ combo: Combo) throws {
        unregister()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: self.id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw RegistrationError(status: status) }
        hotKeyRef = ref
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            return GlobalHotKey.deliver(signature: pressed.signature, id: pressed.id, to: userData) ? noErr : OSStatus(eventNotHandledErr)
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
    }

    /// Runs the action when the pressed shortcut is this one. Carbon calls on the main thread.
    private nonisolated static func deliver(signature: OSType, id: UInt32, to userData: UnsafeMutableRawPointer) -> Bool {
        guard signature == 0x434C_4950 else { return false }
        nonisolated(unsafe) let pointer = userData
        return MainActor.assumeIsolated {
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
            guard hotKey.id == id else { return false }
            hotKey.action()
            return true
        }
    }

    // MARK: - Conversions and labels

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    nonisolated static func symbols(forCarbonModifiers modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(keyCode)] { return name }
        return (characters ?? "?").uppercased()
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            .contains(Int(keyCode))
    }
}
