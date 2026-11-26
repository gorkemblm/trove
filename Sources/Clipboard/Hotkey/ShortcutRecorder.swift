import AppKit
import SwiftUI

/// Click, then press a key combination. Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    var width: CGFloat = 170
    var alignment: HorizontalAlignment = .trailing
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Button {
                recording ? stop(restore: true) : start()
            } label: {
                Text(verbatim: recording ? L("Press a shortcut…") : settings.hotKey.spacedDisplay)
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
                if let message = message ?? app.hotKeyError {
                    Text(message).foregroundStyle(.red)
                } else if settings.hotKey != .default {
                    Button("Reset to \(HotKeySetting.default.display)") { apply(.default) }
                        .buttonStyle(.link)
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
        app.suspendHotKey()
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

    private func apply(_ setting: HotKeySetting) {
        do {
            try app.applyHotKey(setting)
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    private func stop(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording, restore { app.resumeHotKey() }
        recording = false
    }
}
