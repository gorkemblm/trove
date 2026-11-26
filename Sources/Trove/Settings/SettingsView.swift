import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @State private var tab: SettingsTab

    static let size = NSSize(width: 760, height: 640)

    init(app: AppModel, settings: AppSettings, tab: SettingsTab = .general) {
        self.app = app
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab).padding(.top, 6)
            SettingsDivider()
            pages
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var pages: some View {
        ScrollView {
            Group {
                switch tab {
                case .general: GeneralSettings(app: app, settings: settings)
                case .storage: StorageSettings(app: app, settings: settings)
                case .security: SecuritySettings(app: app, settings: settings)
                case .privacy: PrivacySettings(app: app, settings: settings)
                case .shortcuts: ShortcutSettings(settings: settings)
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @State private var loginError: String?
    @State private var showingLicenses = false
    @State private var language = AppLanguage.saved

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { language }, set: { newValue in
            newValue.save()
            language = newValue
        })
    }

    private func groupBinding(_ category: ClipCategory) -> Binding<Bool> {
        let settings = settings
        return Binding(
            get: { MainActor.assumeIsolated { !settings.hiddenGroups.contains(category.rawValue) } },
            set: { on in
                MainActor.assumeIsolated {
                    if on { settings.hiddenGroups.remove(category.rawValue) } else { settings.hiddenGroups.insert(category.rawValue) }
                }
            }
        )
    }

    /// On asks for the folder; Cancel leaves it off.
    private var screenshotBinding: Binding<Bool> {
        let app = app
        return Binding(
            get: { MainActor.assumeIsolated { app.screenshotFolder != nil } },
            set: { on in
                MainActor.assumeIsolated {
                    if on { app.chooseScreenshotFolder() } else { app.stopWatchingScreenshots() }
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSection {
                SettingRow(label: "Startup") {
                    Toggle("Open Trove at login", isOn: Binding(
                        get: { app.launchAtLogin },
                        set: { enabled in
                            do {
                                try app.setLaunchAtLogin(enabled)
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    if let loginError { SettingNote(verbatim: loginError, color: .red) }
                }
                SettingRow(label: "Trove Hotkey", alignment: .top, labelOffset: 9) {
                    ShortcutRecorder(app: app, settings: settings, width: 260, alignment: .leading)
                }
                SettingRow(label: "Recording") {
                    if let status = app.pauseDescription {
                        HStack(spacing: 10) {
                            Label(status, systemImage: "pause.circle.fill").foregroundStyle(.orange).monospacedDigit()
                            Button("Resume") { app.resumeRecording() }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("Pause 10 Minutes") { app.pauseRecording(minutes: 10) }
                            Button("Pause 1 Hour") { app.pauseRecording(minutes: 60) }
                            Button("Pause Until Resumed") { app.pauseRecording(minutes: nil) }
                        }
                    }
                    SettingNote("While paused, nothing you copy is saved, screenshots included. Quitting Trove resumes recording.")
                }
                SettingRow(label: "Pause Shortcut", alignment: .top, labelOffset: 8) {
                    ShortcutRecorder(app: app, settings: settings, width: 260, alignment: .leading, role: .pause)
                }
                SettingRow(label: "Panel Opens In") {
                    SettingMenu(selection: $settings.openingGroup) {
                        ForEach(OpeningGroup.allCases) { Text($0.title).tag($0) }
                    }
                }
                SettingRow(label: "Return Key") {
                    SettingMenu(selection: $settings.returnAction) {
                        ForEach(ReturnAction.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.returnAction == .paste {
                        PastePermissionStatus()
                    }
                }
                SettingRow(label: "Terminal") {
                    let installed = TerminalApp.installed
                    let automatic = TerminalApp.resolve(nil)?.name ?? ""
                    if installed.isEmpty {
                        SettingNote("No terminal app found.")
                    } else {
                        SettingMenu(selection: $settings.terminalBundleID) {
                            Text("Automatic (\(automatic))").tag(String?.none)
                            ForEach(installed) { Text(verbatim: $0.name).tag(Optional($0.bundleID)) }
                        }
                        SettingNote("⌘T on a file or folder opens its folder there.")
                    }
                }
                SettingRow(label: "Language") {
                    SettingMenu(selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    if language != AppLanguage.atLaunch {
                        HStack(spacing: 10) {
                            Text("Restart Trove to use the new language.")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                                .fixedSize()
                            Button("Restart Now") { NSApp.relaunch() }
                        }
                    }
                }
                SettingRow(label: "Menu Bar Icon") {
                    Toggle("Show Trove in the menu bar", isOn: $settings.showMenuBarIcon).toggleStyle(.checkbox)
                }
                SettingRow(label: "Dock Icon") {
                    Toggle("Show Trove in the Dock", isOn: $settings.showDockIcon).toggleStyle(.checkbox)
                    SettingNote("Both icons are off by default: Trove runs in the background. Press ⌘, in the panel to open these settings.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Screenshots") {
                    Toggle("Add new screenshots to history", isOn: screenshotBinding).toggleStyle(.checkbox)
                    if let folder = app.screenshotFolder {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.viewfinder").foregroundStyle(Color.accentColor)
                            Text(StorageLocation.displayPath(folder))
                                .font(.system(size: 12.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change…") { app.chooseScreenshotFolder() }
                        }
                    }
                    if app.screenshotFolderMismatch, let system = app.systemScreenshotFolder {
                        HStack(spacing: 8) {
                            SettingNote("macOS now saves screenshots in “\(StorageLocation.displayPath(system))”.", color: .orange)
                            Button("Use This Folder…") { app.chooseScreenshotFolder() }
                        }
                    }
                    SettingNote("""
                        macOS saves screenshots as files, so they never reach the clipboard. Turn this on and Trove \
                        suggests the folder macOS uses; one click allows it. Screenshots taken with ⌃ (for example ⌃⇧⌘4) \
                        go to the clipboard and are added in any case.
                        """)
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Sidebar Groups", alignment: .top, labelOffset: 1) {
                    LazyVGrid(columns: [GridItem(.fixed(130), alignment: .leading), GridItem(.fixed(130), alignment: .leading),
                                        GridItem(.fixed(130), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(ClipCategory.optional) { category in
                            Toggle(category.parent.map { "\(category.title) (\($0.title))" } ?? category.title, isOn: groupBinding(category))
                                .toggleStyle(.checkbox)
                        }
                    }
                    SettingNote("A group you turn off leaves the sidebar only: its items still show in All and in search.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Appearance", alignment: .top) {
                    AppearancePicker(selection: $settings.panelAppearance)
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Version") {
                    HStack(spacing: 14) {
                        Text("Trove \(AppInfo.version)").monospacedDigit()
                        Button("How Trove Works…") { app.showTour() }
                        Button("Acknowledgements…") { showingLicenses = true }
                        Button("Quit Trove") { app.quit() }
                    }
                }
                .sheet(isPresented: $showingLicenses) { LicensesView() }
                if let updates = app.updates {
                    UpdatesRow(updates: updates)
                }
            }
        }
    }
}

/// Shows whether macOS allows pasting, and rechecks every second while visible, so the status
/// changes as soon as the user allows Clipboard in System Settings.
private struct PastePermissionStatus: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if Paster.isAllowed {
                Label("Allowed in Privacy & Security › Accessibility", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 10) {
                    Text("Needs Accessibility permission. Until then, ↵ only copies.")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize()
                    Button("Allow…") {
                        if !Paster.requestAccess() { Paster.openAccessibilitySettings() }
                    }
                }
            }
        }
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @State private var clearRequest: ClearRequest?
    @State private var exporting = false

    /// A pending "Clear" with the number of items it deletes.
    /// A pending "Clear" with the number of items it deletes. Whole sentences per period, so
    /// each language can phrase them its own way.
    struct ClearRequest {
        enum Period { case hour, day, all }
        let since: Date?
        let period: Period
        let count: Int

        var title: String {
            guard count > 0 else { return L("Nothing to delete") }
            let number = count.formatted()
            switch period {
            case .hour: return String(localized: "Delete \(number) items from the last hour?")
            case .day: return String(localized: "Delete \(number) items from the last 24 hours?")
            case .all: return String(localized: "Delete all \(number) items?")
            }
        }

        var message: String {
            guard count == 0 else { return L("Pinned items, snippets and hidden items are kept. This cannot be undone.") }
            switch period {
            case .hour: return L("No unpinned items were copied in the last hour.")
            case .day: return L("No unpinned items were copied in the last 24 hours.")
            case .all: return L("There are no unpinned items.")
            }
        }
    }

    private func requestClear(_ period: ClearRequest.Period) {
        let since: Date? = switch period {
        case .hour: Date().addingTimeInterval(-3600)
        case .day: Date().addingTimeInterval(-86_400)
        case .all: nil
        }
        clearRequest = ClearRequest(since: since, period: period, count: app.clearableCount(since: since))
    }

    private enum Limit { case retention, items, disk }

    /// Reads the setting; a new value goes through `changeLimits`, which asks before deleting.
    private func limitBinding(_ limit: Limit) -> Binding<Int> {
        let settings = settings, app = app
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    switch limit {
                    case .retention: settings.retentionDays
                    case .items: settings.maxItems
                    case .disk: settings.maxDiskMB
                    }
                }
            },
            set: { value in
                MainActor.assumeIsolated {
                    switch limit {
                    case .retention: app.changeLimits(retentionDays: value)
                    case .items: app.changeLimits(maxItems: value)
                    case .disk: app.changeLimits(maxDiskMB: value)
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSection {
                SettingRow(label: "Location") {
                    HistoryFolderTree(app: app, settings: settings)
                    HStack(spacing: 8) {
                        Button("Change…") { app.chooseStorageLocation() }
                        Button("Show in Finder") { app.revealStorage() }
                    }
                    if let provider = app.storageSyncProvider {
                        SettingNote("Synced by \(provider). It receives only encrypted files.")
                    }
                    if let warning = app.storageWarning {
                        SettingNote(verbatim: warning, color: .orange)
                    }
                    HistoryFolderToggle(app: app, settings: settings)
                    SettingNote("Changing the location, or this option, moves the history.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Keep History") {
                    SettingMenu(selection: limitBinding(.retention)) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                        Text("Forever").tag(0)
                    }
                }
                SettingRow(label: "Maximum Items") {
                    SettingMenu(selection: limitBinding(.items)) {
                        Text("500").tag(500)
                        Text("1,000").tag(1000)
                        Text("5,000").tag(5000)
                        Text("Unlimited").tag(0)
                    }
                }
                SettingRow(label: "Maximum Disk Size") {
                    SettingMenu(selection: limitBinding(.disk)) {
                        Text("250 MB").tag(250)
                        Text("1 GB").tag(1024)
                        Text("5 GB").tag(5120)
                        Text("Unlimited").tag(0)
                    }
                }
                SettingRow(label: "Skip Images Larger Than") {
                    SettingMenu(selection: $settings.maxImageMB) {
                        Text("5 MB").tag(5)
                        Text("20 MB").tag(20)
                        Text("50 MB").tag(50)
                    }
                    SettingNote("Pinned items, snippets and hidden items are never deleted by limits. When a limit is reached, the oldest items go first. A change that deletes items asks first.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "In Use") {
                    Text("\(Formatters.bytes(app.usage.totalBytes)) · \(app.usage.count.formatted()) items · images \(Formatters.bytes(app.usage.imageBytes))")
                        .monospacedDigit()
                }
                SettingRow(label: "Clear History") {
                    HStack(spacing: 8) {
                        Button("Last Hour…") { requestClear(.hour) }
                        Button("Last 24 Hours…") { requestClear(.day) }
                        Button("Everything…") { requestClear(.all) }
                    }
                    SettingNote("Each one asks first and shows how many items it deletes. Pinned items, snippets and hidden items are kept.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Import & Export") {
                    HStack(spacing: 8) {
                        Button("Import…") { app.importHistory() }
                        Button("Export…") { exporting = true }
                    }
                    SettingNote("Import from a Trove export, Raycast, Maccy or Alfred. Export to an encrypted file (best for moving to another Mac), JSON or CSV. Hidden items are never exported.")
                }
            }
        }
        .sheet(isPresented: $exporting) {
            ExportSheet { options in app.exportHistory(options) }
        }
        .onAppear { app.refreshUsage() }
        .confirmationDialog(
            clearRequest?.title ?? "",
            isPresented: Binding(get: { clearRequest != nil }, set: { if !$0 { clearRequest = nil } }),
            presenting: clearRequest
        ) { request in
            if request.count > 0 {
                Button(request.count == 1 ? L("Delete Item") : L("Delete Items"), role: .destructive) { app.clearHistory(since: request.since) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(verbatim: request.message)
        }
    }
}

/// Export choices. The encrypted format needs a password; the others warn that they are readable.
private struct ExportSheet: View {
    let export: (AppModel.ExportOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = AppModel.ExportOptions()
    @State private var password = ""
    @State private var confirmation = ""

    private var valid: Bool {
        options.format != .encrypted || (!password.isEmpty && RecoveryPasswordFields.problem(password, confirmation) == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export History").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Format").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $options.format) {
                        Text("Encrypted Trove export").tag(Transfer.Format.encrypted)
                        Text("JSON (not encrypted)").tag(Transfer.Format.json)
                        Text("CSV, text only (not encrypted)").tag(Transfer.Format.csv)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Items").foregroundStyle(.secondary)
                    Picker("", selection: $options.days) {
                        Text("All").tag(Int?.none)
                        Text("Last 30 days").tag(Int?.some(30))
                        Text("Last 7 days").tag(Int?.some(7))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Pinned items and snippets only", isOn: $options.pinnedOnly)
                        Toggle("Include images", isOn: $options.includeImages).disabled(options.format == .csv)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if options.format == .encrypted {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Password", text: $password)
                    SecureField("Confirm password", text: $confirmation)
                    Text(verbatim: RecoveryPasswordFields.problem(password, confirmation)
                         ?? L("Needed to import the file. Trove does not keep it."))
                        .font(.caption)
                        .foregroundStyle(RecoveryPasswordFields.problem(password, confirmation) == nil ? Color.secondary : Color.orange)
                }
                .textFieldStyle(.roundedBorder)
            } else {
                Label("Not encrypted: anyone with the file can read your history.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    var chosen = options
                    chosen.password = password
                    dismiss()
                    export(chosen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Security

private struct SecuritySettings: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsSection {
                SettingRow(label: "Database") {
                    Label("Encrypted with SQLCipher, AES-256", systemImage: "lock.fill")
                }
                SettingRow(label: "Images") {
                    Label("Encrypted with AES-256-GCM", systemImage: "lock.fill")
                }
                SettingRow(label: "Hidden Items") {
                    Label("Sealed with this Mac’s Secure Enclave", systemImage: "touchid")
                }
                SettingRow(label: "Key") {
                    Label("In the Keychain on this Mac", systemImage: "key.fill")
                    SettingNote("Everything in the history folder is encrypted, including the search index. The key never leaves this Mac and is not synced to iCloud Keychain.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Panel Lock") {
                    Toggle("Require Touch ID to open the panel", isOn: $settings.lockPanel)
                        .toggleStyle(.checkbox)
                    if settings.lockPanel {
                        HStack(spacing: 8) {
                            Text("Lock after").foregroundStyle(.secondary)
                            SettingMenu(selection: $settings.lockAfterMinutes) {
                                Text("Every time it opens").tag(0)
                                Text("1 minute unused").tag(1)
                                Text("5 minutes unused").tag(5)
                                Text("15 minutes unused").tag(15)
                                Text("1 hour unused").tag(60)
                            }
                        }
                    }
                    SettingNote("The panel also locks when the screen locks, the Mac sleeps or another user takes over. While locked, no history is loaded. Touch ID or your Mac password unlocks it.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Recovery Password") {
                    if app.hasRecoveryPassword {
                        Label("Set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Not set").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button(app.hasRecoveryPassword ? L("Change…") : L("Set Password…")) { editing = true }
                            .disabled(app.store == nil)
                        if app.hasRecoveryPassword {
                            Button("Remove…") { confirmRemove = true }
                        }
                    }
                    if let error { SettingNote(verbatim: error, color: .red) }
                    SettingNote("""
                        With a recovery password, this history opens on another Mac or after a reinstall. \
                        Trove does not store the password; if you forget it, the history still opens on this Mac. \
                        Hidden items open only on this Mac.
                        """)
                }
            }
        }
        .sheet(isPresented: $editing) {
            RecoveryPasswordSheet(title: app.hasRecoveryPassword ? L("Change Recovery Password") : L("Set Recovery Password")) { password in
                try app.setRecoveryPassword(password)
                error = nil
            }
        }
        .confirmationDialog("Remove the recovery password?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                do {
                    try app.setRecoveryPassword(nil)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } message: {
            Text("The history then opens only on this Mac. Copies of the key file made before (for example by a sync service) still open with the old password.")
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            SettingsSection {
                SettingRow(label: "Sensitive Content") {
                    SettingMenu(selection: $settings.sensitiveRule) {
                        ForEach(SensitiveRule.allCases) { Text($0.title).tag($0) }
                    }
                    if let error = app.hiddenKeyError { SettingNote(verbatim: error, color: .orange) }
                    SettingNote("""
                        Detected: API keys and tokens (Anthropic, OpenAI, GitHub, AWS, Slack, Google, Stripe), JSON Web Tokens, \
                        private keys, payment card numbers and IBANs. Hidden items open with Touch ID or your password \
                        and never appear in other groups or in search.
                        """)
                }
                SettingRow(label: "Password Managers") {
                    Text("Content they mark as concealed is never saved.")
                }
                SettingRow(label: "Network") {
                    Text("Your history never leaves this Mac. Trove itself has no network access; only its separate update checker connects, to read the list of releases.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Text in Images") {
                    Toggle("Recognize text in images", isOn: Binding(get: { settings.recognizeText }, set: { app.setRecognizeText($0) }))
                        .toggleStyle(.checkbox)
                    SettingNote("""
                        Search then finds screenshots and images by the words in them, and ⌘⇧C copies their text. \
                        Apple’s Vision reads them on this Mac; the text is stored encrypted with your history. \
                        Images already in your history are read in the background.
                        """)
                    RecognitionStatus(app: app, settings: settings)
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Source") {
                    Toggle("Record the page address when copying from Chromium browsers", isOn: $settings.recordSourceURL)
                        .toggleStyle(.checkbox)
                    SettingNote("Arc, Chrome, Edge and Brave add the page address to copied content. It shows as “Copied from” in the details.")
                }
            }
            SettingsDivider()
            SettingsSection {
                SettingRow(label: "Ignored Apps", alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(Array(settings.excludedApps.enumerated()), id: \.element.id) { index, excluded in
                            if index > 0 { SettingsDivider() }
                            HStack(spacing: 10) {
                                if let icon = AppIcons.icon(for: excluded.bundleID) {
                                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "app.dashed").frame(width: 20, height: 20)
                                }
                                Text(excluded.name)
                                Spacer(minLength: 8)
                                Button {
                                    app.removeExcludedApp(excluded)
                                } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Stop ignoring \(excluded.name)")
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                        }
                    }
                    .frame(maxWidth: 400)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
                    Button("Add App…") { app.addExcludedApp() }
                    SettingNote("Nothing copied in these apps is saved.")
                }
            }
        }
    }
}

// MARK: - Shortcuts

/// The same layout as the other tabs: a group name on the left, a card on the right; each card
/// row names an action and shows its keys at the right edge.
private struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings

    private var sections: [(title: String, rows: [(String, [String])])] {
        [
            (L("Panel"), [
                (L("Open Trove"), GlobalHotKey.symbols(forCarbonModifiers: settings.hotKey.modifiers).map(String.init) + [settings.hotKey.keyLabel]),
                (L("Pause or resume recording (in the panel)"), ["⌥", "P"]),
                (L("Pause or resume recording"), settings.pauseHotKey.map {
                    GlobalHotKey.symbols(forCarbonModifiers: $0.modifiers).map(String.init) + [$0.keyLabel]
                } ?? [L("Not set")]),
                (L("All actions"), ["⌘", "K"]),
                (L("Settings"), ["⌘", ","]),
                (L("Clear search, then close"), ["esc"]),
                (L("Quit Trove"), ["⌘", "Q"]),
            ]),
            (L("Items"), [
                (L("Paste (or copy) the selected item"), ["↵"]),
                (L("Paste (or copy) as plain text"), ["⇧", "↵"]),
                (L("Open link, compose email, call, show in Finder"), ["⌘", "↵"]),
                (L("Open a file’s folder in the terminal"), ["⌘", "T"]),
                (L("Copy the text in an image"), ["⌘", "⇧", "C"]),
                (L("Edit and transform the text"), ["⌘", "E"]),
                (L("Save as a snippet (kept for good)"), ["⌘", "S"]),
                (L("Pin or unpin"), ["⌘", "P"]),
                (L("Move to Hidden, or back"), ["⌘", "⇧", "H"]),
                (L("Name a hidden item"), ["⌘", "R"]),
                (L("Delete (asks first)"), ["⌘", "D"]),
            ]),
            (L("Navigation"), [
                (L("Move the selection"), ["↑", "↓"]),
                (L("Go to groups, back to items"), ["←", "→"]),
                (L("Change group (in groups)"), ["↑", "↓"]),
                (L("All, Text, Links, Images, Files"), ["⌘", "1…5"]),
                (L("Go to a group"), ["/"]),
                (L("Only items from one app"), ["@"]),
            ]),
            (L("Selecting"), [
                (L("Select several items"), ["⌘", "⇧", "S"]),
                (L("Add or remove one item"), ["⌘", L("Click")]),
                (L("Select a range"), ["⇧", "↑", "↓"]),
                (L("Select all (while selecting)"), ["⌘", "A"]),
            ]),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { SettingsDivider() }
                SettingsSection {
                    SettingRow(verbatim: section.title, alignment: .top, labelOffset: 10) {
                        card(section.rows)
                    }
                    if index == 0 {
                        SettingRow(label: "") {
                            SettingNote("Change the shortcut that opens the panel in General.")
                        }
                    }
                }
            }
        }
    }

    private func card(_ rows: [(String, [String])]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
                HStack(spacing: 12) {
                    Text(verbatim: row.0).font(.system(size: 13))
                    Spacer(minLength: 12)
                    HStack(spacing: 4) {
                        ForEach(Array(row.1.enumerated()), id: \.offset) { _, key in
                            Text(verbatim: key)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 7)
                                .frame(minWidth: 26, minHeight: 24)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            }
        }
        .frame(maxWidth: 460)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// Two password fields with length and match checks. Used in Settings and onboarding.
struct RecoveryPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String

    static func problem(_ password: String, _ confirmation: String) -> String? {
        if password.isEmpty && confirmation.isEmpty { return nil }
        if password.count < Vault.minimumPasswordLength {
            let minimum = Vault.minimumPasswordLength.formatted()
            return String(localized: "Use at least \(minimum) characters.")
        }
        if password != confirmation { return L("The passwords do not match.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Recovery password", text: $password)
            SecureField("Confirm password", text: $confirmation)
            Text(verbatim: Self.problem(password, confirmation) ?? L("A long passphrase is best: the key file may be copied by sync services."))
                .font(.caption)
                .foregroundStyle(Self.problem(password, confirmation) == nil ? Color.secondary : Color.orange)
                .frame(height: 16, alignment: .topLeading)
        }
        .textFieldStyle(.roundedBorder)
    }
}

private struct RecoveryPasswordSheet: View {
    let title: String
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?

    private var valid: Bool {
        !password.isEmpty && RecoveryPasswordFields.problem(password, confirmation) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            RecoveryPasswordFields(password: $password, confirmation: $confirmation)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try save(password)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}


/// The licences of the libraries inside the app (Resources/Licenses), as their terms require.
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private static let files = ["GRDB", "SQLCipher", "Sparkle"]

    private func text(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Licenses")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Acknowledgements").font(.system(size: 17, weight: .semibold))
            Text("Trove is built with these open-source libraries.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.files, id: \.self) { name in
                        Text(verbatim: text(name))
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}

/// "Reading images: 120 of 300" while the first run goes on; the remove button while it is off.
private struct RecognitionStatus: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        // Refreshes while Settings is open, without the indexer touching the view.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let progress = (try? app.store?.recognitionProgress()) ?? (done: 0, total: 0)
            if settings.recognizeText {
                if progress.total > 0, progress.done < progress.total {
                    SettingNote(verbatim: String(localized: "Reading images: \(progress.done.formatted()) of \(progress.total.formatted())"))
                }
            } else if progress.done > 0 {
                HStack(spacing: 10) {
                    Button("Remove Recognized Text…") { app.confirmClearRecognizedText() }
                    SettingNote(verbatim: String(localized: "Kept for \(progress.done.formatted()) images"))
                }
            }
        }
    }
}

/// Settings › General › Updates: check now, and whether to check every day.
private struct UpdatesRow: View {
    @ObservedObject var updates: Updates

    var body: some View {
        SettingRow(label: "Updates") {
            HStack(spacing: 14) {
                Button("Check for Updates…", action: updates.check).disabled(!updates.canCheck)
                Toggle("Check automatically", isOn: Binding(get: { updates.checksAutomatically },
                                                            set: { updates.checksAutomatically = $0 }))
                    .toggleStyle(.checkbox)
            }
            if let last = updates.lastCheck {
                SettingNote(verbatim: String(localized: "Last checked \(last.formatted(.relative(presentation: .named)))"))
            } else {
                SettingNote("Updates are signed and notarized. Your history is never sent anywhere.")
            }
        }
    }
}
