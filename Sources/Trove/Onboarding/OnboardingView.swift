import SwiftUI

/// Five steps: welcome, storage location, encryption (optional recovery password), how Trove
/// works (animated demos), shortcut and startup options.
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @State private var step: Int
    @State private var openAtLogin = true
    @State private var password = ""
    @State private var confirmation = ""
    @State private var passwordError: String?
    @State private var language = AppLanguage.saved

    private let stepCount = 5
    static let size = NSSize(width: 600, height: 580)

    init(app: AppModel, settings: AppSettings, step: Int = 0) {
        self.app = app
        self.settings = settings
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: storage
                case 2: security
                case 3: tour
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 52)

            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<stepCount, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityLabel("Step \(step + 1) of \(stepCount)")
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                primaryButton
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .frame(height: 68)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case 0:
            Button("Get Started") { step = 1 }
                .keyboardShortcut(.defaultAction)
        case 1:
            Button("Continue") { step = 2 }
                .keyboardShortcut(.defaultAction)
                .disabled(app.store == nil)
        case 2:
            Button(password.isEmpty ? L("Continue Without") : L("Set and Continue")) { finishSecurityStep() }
                .keyboardShortcut(.defaultAction)
                .disabled(RecoveryPasswordFields.problem(password, confirmation) != nil)
        case 3:
            Button("Continue") { step = 4 }
                .keyboardShortcut(.defaultAction)
        default:
            Button("Start Using Trove") { app.finishOnboarding(openAtLogin: openAtLogin) }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Steps

    private var tour: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How Trove works").font(.system(size: 22, weight: .bold))
            Text("Eight short demos. ← → move between them; ⌘K shows them again later.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DemoTour(compact: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.leading, -6) // The icon art has a margin of its own.
            Text("Welcome to Trove")
                .font(.system(size: 26, weight: .bold))
            Text("Trove keeps what you copy, so you can find it again.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "square.grid.2x2", title: "Text, links, images and files",
                        detail: "Grouped by type, searchable, with details for every item.")
                Feature(symbol: "keyboard", title: "Opens with \(settings.hotKey.display)",
                        detail: "From any app. Esc closes it.")
                Feature(symbol: "lock.shield", title: "Encrypted, and stays on this Mac",
                        detail: "The key is in your Keychain. Your history never leaves this Mac. Password manager content is never saved.")
            }
            .padding(.top, 12)
            // The language first: the rest of the setup and its demos follow it.
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text("Language")
                Picker("", selection: Binding(get: { language }, set: { language = $0; $0.save() })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if language != AppLanguage.atLaunch {
                    Button("Restart in This Language") { NSApp.relaunch() }
                }
            }
            .padding(.top, 14)
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where should Trove keep your history?")
                .font(.system(size: 22, weight: .bold))
            Text("Choose a location. Trove creates a “\(StorageLocation.historyFolderName)” folder there. It holds an encrypted database, encrypted images and a key file.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Image(systemName: app.store == nil ? "folder.badge.questionmark" : "folder.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(app.store == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: app.store == nil ? L("No location chosen yet") : app.storageDirectory.lastPathComponent)
                        .font(.headline)
                    if app.store != nil {
                        Text(StorageLocation.displayPath(app.storageDirectory))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Button(app.store == nil ? L("Choose…") : L("Change…")) { app.chooseStorageLocation() }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 6)

            if app.store != nil, let provider = app.storageSyncProvider {
                Label("This folder is synced by \(provider). It receives only encrypted files.",
                      systemImage: "lock.icloud")
                    .foregroundStyle(.secondary)
            }
            if app.store != nil {
                // Apps found on this Mac, with their icons: their history can come along.
                let found = ImportSource.nearby.filter { $0 != .trove }
                Button { app.importHistory() } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: -6) {
                            ForEach(found.isEmpty ? [.trove] : found) { SourceIcon(source: $0, size: 26) }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(found.isEmpty ? L("Import history from another app…")
                                 : String(localized: "Bring your history from \(found.map(\.title).formatted(.list(type: .and)))…"))
                                .font(.system(size: 13, weight: .medium))
                            Text("Nothing is saved until you confirm.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Label("A synced folder works: everything in it is encrypted. To open the history on another Mac, set a recovery password in the next step.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your history is encrypted")
                .font(.system(size: 22, weight: .bold))
            Text("The database, its search index and every image are encrypted with AES-256. The key is kept in this Mac’s Keychain, so Trove never asks for a password.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Recovery password (optional)").font(.headline)
                Text("Opens this history on another Mac or after a reinstall. Without it, the history opens only on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if app.hasRecoveryPassword {
                    Label("A recovery password is set. Change it later in Settings › Security.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(height: 76, alignment: .topLeading)
                } else {
                    RecoveryPasswordFields(password: $password, confirmation: $confirmation)
                }
                if let passwordError {
                    Text(passwordError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 6)

            Text("Trove does not store this password. If you forget it, the history still opens on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finishSecurityStep() {
        guard !password.isEmpty, !app.hasRecoveryPassword else {
            step = 3
            return
        }
        do {
            try app.setRecoveryPassword(password)
            password = ""
            confirmation = ""
            passwordError = nil
            step = 3
        } catch {
            passwordError = error.localizedDescription
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You’re all set")
                .font(.system(size: 22, weight: .bold))
            Text("Trove runs in the background, without a Dock or menu bar icon.")
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Text("Open the panel with").padding(.top, 8)
                    Spacer()
                    ShortcutRecorder(app: app, settings: settings, width: 170)
                }
                .padding(.top, 12)
                .padding(.bottom, 4)
                Divider()
                switchRow("Open Trove at login", isOn: $openAtLogin)
                Divider()
                switchRow("Paste into the active app with ↵", isOn: Binding(
                    get: { settings.returnAction == .paste },
                    set: { on in
                        settings.returnAction = on ? .paste : .copy
                        settings.pastePromptAnswered = true
                        if on, !Paster.isAllowed, !Paster.requestAccess() { Paster.openAccessibilitySettings() }
                    }
                ))
                Divider()
                switchRow("Add screenshots to history", isOn: Binding(
                    get: { app.screenshotFolder != nil },
                    set: { on in
                        if on { app.chooseScreenshotFolder() } else { app.stopWatchingScreenshots() }
                    }
                ))
                Divider()
                switchRow("Find images by the text in them", isOn: Binding(
                    get: { settings.recognizeText }, set: { app.setRecognizeText($0) }
                ), note: "Read on this Mac. Images already in your history are read in the background.")
                Divider()
                switchRow("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            }
            .padding(.horizontal, 14)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 6)

            Text("Change these later in Settings: press ⌘, while the panel is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Label on the left, switch on the right edge.
    private func switchRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, note: LocalizedStringKey? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, note == nil ? 8 : 6)
    }
}

private struct Feature: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
