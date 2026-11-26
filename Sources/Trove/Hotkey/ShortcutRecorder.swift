import AppKit
import SwiftUI

/// Click, then press a key combination. Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    var width: CGFloat = 170
    var alignment: HorizontalAlignment = .trailing
    /// The panel shortcut (always set), or the pause shortcut (optional).
    var role: HotKeyRole = .panel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Button {
                recording ? stop(restore: true) : start()
            } label: {
                Text(verbatim: recording ? L("Press a shortcut…") : (current?.spacedDisplay ?? L("Click to set")))
                    .font(.system(size: recording ? 13 : 15, weight: .medium))
                    .foregroundStyle(recording ? Color.secondary : Color.primary)
                    .frame(width: width, height: 34)
                    .background(Color.primary.opacity(recording ? 0.04 : 0.08),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: recording ? 2 : 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Click, then press a key combination. Esc cancels.")
            // Fixed height, so the rows below do not move when the link appears.
            Group {
                if let message = message ?? (role == .panel ? app.hotKeyError : nil) {
                    Text(message).foregroundStyle(.red)
                } else if role == .panel, settings.hotKey != .default {
                    Button("Reset to \(HotKeySetting.default.display)") { apply(.default) }
                        .buttonStyle(.link)
                } else if role == .pause, settings.pauseHotKey != nil {
                    Button("Remove Shortcut") { apply(nil) }
                        .buttonStyle(.link)
                } else if role == .pause {
                    // The same line as the link above, so nothing moves when a shortcut is set.
                    Text("From any app. In the panel, ⌥P does it too.").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.system(size: 12))
            .frame(height: 15)
        }
        .onDisappear { stop(restore: true) }
    }

    private func start() {
        message = nil
        recording = true
        app.suspendHotKey(role)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let characters = event.charactersIgnoringModifiers
            MainActor.assumeIsolated { handle(keyCode: keyCode, flags: flags, characters: characters) }
            return nil
        }
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        if keyCode == 53, flags.isEmpty { // Esc
            stop(restore: true)
            return
        }
        let hasModifier = !flags.intersection([.command, .option, .control]).isEmpty
        guard hasModifier || GlobalHotKey.isFunctionKey(keyCode) else {
            message = L("Use at least one of ⌘ ⌥ ⌃.")
            return
        }
        let setting = HotKeySetting(
            keyCode: UInt32(keyCode),
            modifiers: GlobalHotKey.carbonModifiers(from: flags),
            keyLabel: GlobalHotKey.keyLabel(keyCode: keyCode, characters: characters)
        )
        stop(restore: false)
        apply(setting)
    }

    private var current: HotKeySetting? { role == .panel ? settings.hotKey : settings.pauseHotKey }

    private func apply(_ setting: HotKeySetting?) {
        do {
            try app.applyHotKey(setting, role: role)
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    private func stop(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording, restore { app.resumeHotKey(role) }
        recording = false
    }
}
