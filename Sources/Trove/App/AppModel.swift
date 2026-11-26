import AppKit
import Combine
import LocalAuthentication
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

/// Owns the store, the clipboard monitor, the panel, the hot key and the settings window.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()

    @Published private(set) var store: Store?
    @Published private(set) var storageDirectory: URL = StorageLocation.defaultDirectory
    @Published private(set) var storageWarning: String?
    @Published private(set) var usage = StoreUsage()
    @Published private(set) var hotKeyError: String?
    @Published private(set) var hasRecoveryPassword = false

    let vault = Vault(keyStore: KeychainKeyStore())
    /// The key of the open store. Needed to set or change the recovery password.
    private var dataKey: DataKey?
    /// The Secure Enclave key for hidden items. Loaded when first needed.
    private var hiddenKey: HiddenKey?
    @Published private(set) var hiddenKeyError: String?
    private var expiryTimer: Timer?

    /// Recording is paused until this time (`.distantFuture`: until resumed). Not saved: a
    /// restart resumes recording.
    @Published private(set) var pausedUntil: Date?
    private var pauseTimer: Timer?
    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    /// Panel lock: true after a screen lock, sleep or log-out switch, until Touch ID.
    private var lockRequired = true
    private var lastPanelUse = Date.distantPast
    private var lockObservers: [NSObjectProtocol] = []
    /// The watched screenshot folder, or nil when screenshots saved as files are not added.
    @Published private(set) var screenshotFolder: URL?
    private var screenshotWatcher: ScreenshotWatcher?

    private(set) lazy var panelModel = PanelModel(app: self)
    private(set) lazy var textIndexer = TextIndexer(app: self)
    /// Sparkle. Started by `start()` only (tests and snapshots run without it).
    private(set) var updates: Updates?
    private var panel: PanelController?
    private let toast = CopyToast()
    private let previewWindow = PreviewWindowController()
    private var hotKey: GlobalHotKey?
    private let monitor = PasteboardMonitor()
    private var statusItem: NSStatusItem?
    private var statusActions: [MenuAction] = []
    private var settingsWindow: SettingsWindowController?
    private var scopedDirectory: URL?
    private var pruneTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let log = Logger(subsystem: AppInfo.bundleID, category: "app")

    // MARK: - Start

    func start() {
        _ = AppLanguage.atLaunch // Read now: a later change in Settings then shows "Restart Now".
        updates = Updates()
        panel = PanelController(model: panelModel)
        panel?.apply(settings.panelAppearance)
        toast.apply(settings.panelAppearance)
        previewWindow.onClose = { [weak self] in
            self?.panel?.releaseOpen(.preview)
            self?.panel?.refocus()
        }
        hotKey = GlobalHotKey { [weak self] in self?.togglePanel() }
        pauseHotKey = GlobalHotKey { [weak self] in self?.togglePauseFromShortcut() }
        resumeHotKey()
        resumeHotKey(.pause)
        if hotKeyError != nil {
            // After a restart (language change) the old copy may still hold the shortcut for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.resumeHotKey() }
        }

        applyDockIcon(settings.showDockIcon)
        applyStatusItem(settings.showMenuBarIcon)
        observeSettings()
        observeLockEvents()

        if settings.onboardingCompleted {
            let directory = resolveStorageDirectory()
            if !openStore(at: directory, quitOnCancel: true), directory != StorageLocation.defaultDirectory {
                openStore(at: StorageLocation.defaultDirectory)
            }
            startCapture()
        } else {
            // Set up before (onboarding shown again): the history it already has opens, so the
            // storage step shows that folder and nothing starts from scratch.
            if settings.storageBookmark != nil {
                _ = openStore(at: resolveStorageDirectory(), quitOnCancel: false)
            }
            // Nothing is recorded until onboarding is finished.
            showOnboarding()
        }
        log.info("Trove \(AppInfo.version, privacy: .public) started")
        log.info("macOS screenshot folder: \(self.systemScreenshotFolder?.path ?? "clipboard", privacy: .public)")
    }

    private func startCapture() {
        monitor.isExcluded = { [weak self] bundleID in
            guard let self, let bundleID else { return false }
            return self.settings.excludedApps.contains { $0.bundleID == bundleID }
        }
        monitor.recordSourceURL = { [weak self] in self?.settings.recordSourceURL ?? false }
        monitor.maxImageBytes = { [weak self] in (self?.settings.maxImageMB ?? 20) * 1_048_576 }
        monitor.onCapture = { [weak self] content, source in self?.ingest(content, source: source) }
        monitor.start()
        startScreenshotWatcher()
        if screenshotFolder == nil, !settings.screenshotPromptAnswered, systemScreenshotFolder != nil {
            DispatchQueue.main.async { [weak self] in self?.askToAddScreenshots() }
        }
        if settings.returnAction == .paste, !Paster.isAllowed, !settings.pastePromptAnswered {
            DispatchQueue.main.async { [weak self] in self?.askToPaste() }
        }

        prune()
        if pruneTimer == nil {
            let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.prune() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pruneTimer = timer
        }
    }

    /// Snapshot mode only: renders the panel from an in-memory store.
    func installStoreForSnapshots(_ store: Store, hiddenKey: HiddenKey) {
        self.store = store
        self.hiddenKey = hiddenKey
        // Tests and snapshots share one defaults domain: each starts in All, not in the group
        // an earlier one left open.
        settings.openingGroup = .all
        settings.lastGroup = ClipCategory.all.rawValue
        // A typical chosen location for the Settings and onboarding pictures (never written to).
        storageDirectory = URL(fileURLWithPath: StorageLocation.realHome + "/Documents", isDirectory: true)
            .appendingPathComponent(StorageLocation.historyFolderName, isDirectory: true)
    }

    // MARK: - Onboarding

    private var onboardingWindow: OnboardingWindowController?

    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(app: self)
        }
        onboardingWindow?.show()
    }

    func finishOnboarding(openAtLogin: Bool) {
        guard store != nil else { return }
        settings.onboardingCompleted = true
        settings.screenshotPromptAnswered = true // The ready step has its own switches.
        settings.pastePromptAnswered = true
        if openAtLogin, !launchAtLogin {
            do {
                try setLaunchAtLogin(true)
            } catch {
                log.error("Open at login failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        onboardingWindow?.close()
        onboardingWindow = nil
        startCapture()
        showPanel()
    }

    private func observeSettings() {
        settings.$showMenuBarIcon.dropFirst().sink { [weak self] show in
            MainActor.assumeIsolated { self?.applyStatusItem(show) }
        }.store(in: &cancellables)

        settings.$panelAppearance.dropFirst().sink { [weak self] appearance in
            MainActor.assumeIsolated {
                self?.panel?.apply(appearance)
                self?.toast.apply(appearance)
                self?.settingsWindow?.apply(appearance, animated: true)
                self?.onboardingWindow?.apply(appearance, animated: true)
                self?.tourWindow?.apply(appearance)
                self?.importWindow?.apply(appearance)
            }
        }.store(in: &cancellables)

        settings.$showDockIcon.dropFirst().sink { [weak self] show in
            MainActor.assumeIsolated { self?.applyDockIcon(show) }
        }.store(in: &cancellables)
    }

    // MARK: - Capture

    /// Every capture goes through here (clipboard monitor and screenshot folder).
    func ingest(_ content: CapturedContent, source: ClipSource) {
        guard let store, !isPaused else { return }
        if content.kind.isTextual, let text = content.text,
           let finding = SensitiveDetector.detect(text) {
            ingestSecret(text, finding: finding, source: source, store: store)
            return
        }
        do {
            try store.ingest(content, source: source, at: Date())
            try store.prune(currentLimits)
        } catch {
            log.error("Saving a clip failed: \(error.localizedDescription, privacy: .public)")
        }
        panelModel.storeDidChange()
        if content.imageData != nil { textIndexer.start() } // Its text is read in the background.
    }

    // MARK: - Text in images

    /// Settings and onboarding. On: images not read yet are read in the background.
    func setRecognizeText(_ on: Bool) {
        settings.recognizeText = on
        if on { textIndexer.start() } else { textIndexer.stop() }
    }

    /// A text was read: the detail shows its badge and "Copy Text" at once.
    func recognitionDidUpdate(id: Int64) {
        panelModel.recognitionDidUpdate(id: id)
    }

    /// Settings › Privacy, while recognition is off: forgets every recognized text, after asking.
    func confirmClearRecognizedText() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove the text read from images?")
        alert.informativeText = String(localized: "Search no longer finds images by their text. The images stay in your history.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store?.clearRecognizedText()
            panelModel.storeDidChange()
        } catch {
            showError(String(localized: "The text could not be removed"), error)
        }
    }

    // MARK: - Screenshots

    /// Starts watching the saved screenshot folder, or stops when none is saved.
    private func startScreenshotWatcher() {
        screenshotWatcher?.stop()
        screenshotWatcher = nil
        screenshotFolder?.stopAccessingSecurityScopedResource()
        screenshotFolder = nil
        guard let bookmark = settings.screenshotBookmark else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            log.error("Screenshot folder bookmark could not be resolved")
            return
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            settings.screenshotBookmark = fresh
        }
        let watcher = ScreenshotWatcher(directory: url) { [weak self] file in self?.ingestScreenshot(file) }
        guard watcher.start() else {
            url.stopAccessingSecurityScopedResource()
            log.error("Screenshot folder could not be watched")
            return
        }
        screenshotWatcher = watcher
        screenshotFolder = url
        log.info("Watching screenshots in \(url.path, privacy: .public)")
    }

    private func ingestScreenshot(_ file: URL) {
        let maxBytes = settings.maxImageMB * 1_048_576
        guard let data = try? Data(contentsOf: file),
              var content = ClipClassifier.imageContent(data: data, maxBytes: maxBytes) else {
            log.info("A screenshot was skipped (not an image, or larger than the image limit)")
            return
        }
        content.text = file.path // For "Show in Finder" and search by file name.
        ingest(content, source: ClipSource(bundleID: Clip.screenshotSource, appName: "Screenshot", url: nil))
        log.info("Screenshot added (\(content.imageWidth ?? 0) × \(content.imageHeight ?? 0))")
    }

    /// Asked once: pasting directly needs Accessibility permission. Without it ↵ only copies.
    private func askToPaste() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Paste directly into apps?")
        alert.informativeText = String(localized: """
            With ↵, Trove can paste the chosen item into the app you were using, instead of only copying it. \
            macOS asks you to allow this once, in Privacy & Security › Accessibility. Trove uses it only to send ⌘V.
            """)
        alert.addButton(withTitle: String(localized: "Allow…"))
        alert.addButton(withTitle: String(localized: "Only Copy"))
        NSApp.activate()
        let allow = alert.runModal() == .alertFirstButtonReturn
        settings.pastePromptAnswered = true
        if allow {
            if !Paster.requestAccess() { Paster.openAccessibilitySettings() }
        } else {
            settings.returnAction = .copy
        }
    }

    /// After the item is on the clipboard and the panel closed: pastes with ⌘V when the user
    /// chose that and macOS allows it; otherwise confirms the copy.
    private func finishCopy(_ message: String) {
        if settings.returnAction == .paste, Paster.isAllowed {
            Paster.pasteSoon()
        } else {
            toast.show(message)
        }
    }

    /// Asked once: macOS saves screenshots as files, so they are not added unless the user
    /// allows Clipboard to read that folder.
    private func askToAddScreenshots() {
        guard let folder = systemScreenshotFolder else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Add screenshots to Trove?")
        alert.informativeText = String(localized: """
            macOS saves screenshots as files in “\(StorageLocation.displayPath(folder))”, so they never reach the clipboard. \
            Trove can add each new screenshot to Images. Next, click Watch Folder to allow it.
            """)
        alert.addButton(withTitle: String(localized: "Allow…"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        let allow = alert.runModal() == .alertFirstButtonReturn
        settings.screenshotPromptAnswered = true
        if allow { chooseScreenshotFolder() }
    }

    /// Where macOS saves screenshots: the Screenshot app's "Save to" setting, or the Desktop.
    /// Nil when macOS puts screenshots on the clipboard (those are captured anyway).
    var systemScreenshotFolder: URL? {
        let domain = "com.apple.screencapture" as CFString
        if (CFPreferencesCopyAppValue("target" as CFString, domain) as? String) == "clipboard" { return nil }
        let home = StorageLocation.realHome
        guard var path = CFPreferencesCopyAppValue("location" as CFString, domain) as? String, !path.isEmpty else {
            return URL(fileURLWithPath: home).appendingPathComponent("Desktop", isDirectory: true)
        }
        if path.hasPrefix("~") { path = home + path.dropFirst() }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// True when screenshots are watched in a folder other than the one macOS now uses.
    var screenshotFolderMismatch: Bool {
        guard let watched = screenshotFolder, let system = systemScreenshotFolder else { return false }
        return watched.standardizedFileURL.path != system.standardizedFileURL.path
    }

    /// Opens the folder panel at the macOS screenshot folder, so one click allows it.
    /// The sandbox lets the app read a folder only after the user chooses it once.
    @discardableResult
    func chooseScreenshotFolder() -> Bool {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = String(localized: "Watch Folder")
        let system = systemScreenshotFolder
        openPanel.message = system.map {
            String(localized: "macOS saves screenshots in “\(StorageLocation.displayPath($0))”. Click Watch Folder to let Trove add new ones, or choose another folder.")
        } ?? String(localized: "Choose the folder to watch for screenshots.")
        openPanel.directoryURL = system ?? URL(fileURLWithPath: StorageLocation.realHome).appendingPathComponent("Desktop")
        NSApp.activate()
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return false }
        do {
            settings.screenshotBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            showError(String(localized: "The folder cannot be watched"), error)
            return false
        }
        startScreenshotWatcher()
        return screenshotFolder != nil
    }

    func stopWatchingScreenshots() {
        settings.screenshotBookmark = nil
        startScreenshotWatcher()
    }

    // MARK: - Hidden items

    private func loadHiddenKey() -> HiddenKey? {
        if let hiddenKey { return hiddenKey }
        do {
            let existed = try vault.keyStore.load(account: SecureEnclaveHiddenKey.account) != nil
            let key = try SecureEnclaveHiddenKey.loadOrCreate(keyStore: vault.keyStore)
            hiddenKey = key
            hiddenKeyError = nil
            // A new key while the history already has hidden items: those were sealed to a key
            // this Mac no longer has (a Keychain reset, or a history from another Mac). They stay,
            // but they cannot be opened; the user is told once instead of finding out later.
            if !existed, (try? store?.hasSealedItems()) == true {
                DispatchQueue.main.async { [weak self] in self?.showLostHiddenKeyNotice() }
            }
            return key
        } catch {
            hiddenKeyError = error.localizedDescription
            log.error("Hidden key unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func showLostHiddenKeyNotice() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Older hidden items cannot be opened on this Mac")
        alert.informativeText = String(localized: "The key that protected them is no longer in this Mac’s Keychain (a Keychain reset, or a history copied from another Mac). They stay in Hidden until you delete them. New hidden items use a new key and open as usual.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// A detected secret goes to Hidden, sealed to the hidden key, or is not saved.
    /// Without a hidden key it is not saved: it never goes to the normal history.
    private func ingestSecret(_ text: String, finding: SensitiveDetector.Finding, source: ClipSource, store: Store) {
        guard settings.sensitiveRule != .discard, let key = loadHiddenKey() else {
            log.info("A copied secret was not saved (\(finding.reason, privacy: .public))")
            return
        }
        do {
            let sealed = try SealedSecret.seal(Data(text.utf8), to: key.publicKey)
            let now = Date()
            let expiry = settings.sensitiveRule == .hideOneMinute ? now.addingTimeInterval(60) : nil
            try store.ingestSecret(sealed: sealed, finding: finding, characters: text.count, source: source,
                                   at: now, expiresAt: expiry)
            try store.prune(currentLimits)
            log.info("A copied secret was saved in Hidden (\(finding.reason, privacy: .public))")
        } catch {
            log.error("Saving a hidden item failed: \(error.localizedDescription, privacy: .public)")
        }
        scheduleExpiry()
        panelModel.storeDidChange()
    }

    /// Runs a prune when the next hidden item is due to delete itself.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let next = try? store?.nextExpiry() else { return }
        let timer = Timer(fire: max(next, Date()).addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prune()
                self?.scheduleExpiry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Asks for Touch ID (or the Mac password). The panel stays open during the prompt.
    ///
    /// The prompt closes a moment after it reports the result and moves the focus once more,
    /// so the panel stays open for a short grace period and takes the focus back twice.
    func authenticate(reason: String, _ completion: @escaping @MainActor (LAContext?) -> Void) {
        let context = LAContext()
        panel?.holdOpen(.touchID)
        log.info("Touch ID requested: \(reason, privacy: .public)")
        Task { @MainActor in
            var granted = false
            do {
                granted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch let error as LAError {
                log.info("Touch ID ended: LAError \(error.code.rawValue, privacy: .public)")
                if ![.userCancel, .systemCancel, .appCancel].contains(error.code) {
                    toast.show(String(localized: "Touch ID is not available"), symbol: "exclamationmark.circle.fill", tint: .orange)
                }
            } catch {
                log.error("Touch ID failed: \(error.localizedDescription, privacy: .public)")
            }
            log.info("Touch ID \(granted ? "granted" : "not granted", privacy: .public)")
            panel?.refocus()
            completion(granted ? context : nil)
            try? await Task.sleep(for: .milliseconds(600))
            panel?.refocus()
            panel?.releaseOpen(.touchID)
        }
    }

    /// The content of a hidden item. Nil when it cannot be opened (for example, it was sealed
    /// on another Mac).
    func reveal(_ clip: Clip, context: LAContext?) -> String? {
        guard let id = clip.id, let full = try? store?.clip(id: id), let sealed = full.sealed,
              let key = loadHiddenKey(),
              let data = try? SealedSecret.open(sealed, with: key, context: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Moves a text item to Hidden on purpose, with an optional name. Needs no Touch ID: sealing
    /// uses only the public half of the hidden key.
    func hideItem(_ clip: Clip, name: String?) {
        guard let store, let id = clip.id, let full = try? store.clip(id: id), full.kind.isTextual,
              let text = full.text, !text.isEmpty else { NSSound.beep(); return }
        guard let key = loadHiddenKey() else {
            showError(L("The item could not be hidden"), HiddenKeyError.secureEnclaveUnavailable)
            return
        }
        do {
            let sealed = try SealedSecret.seal(Data(text.utf8), to: key.publicKey)
            try store.hide(id: id, sealed: sealed, characters: text.count, name: name)
            log.info("An item was moved to Hidden by the user")
            toast.show(L("Moved to Hidden"), symbol: "lock.fill", tint: .accentColor)
        } catch {
            showError(L("The item could not be hidden"), error)
        }
        panelModel.storeDidChange()
    }

    func renameHidden(_ clip: Clip, name: String?) {
        guard let id = clip.id else { return }
        try? store?.renameSecret(id: id, name: name)
        panelModel.storeDidChange()
    }

    /// Moves a revealed hidden item back to the normal history.
    func unhideItem(_ clip: Clip, text: String) {
        guard let store, let id = clip.id else { return }
        do {
            try store.unhide(id: id, content: ClipClassifier.textContent(text, rtf: nil))
            log.info("A hidden item was moved back by the user")
            toast.show(L("Moved Back to History"), symbol: "lock.open.fill", tint: .accentColor)
        } catch {
            showError(L("The item could not be moved back"), error)
        }
        panelModel.storeDidChange()
    }

    /// Copies a revealed hidden item, marked as concealed for other clipboard managers.
    func copySecret(_ clip: Clip, text: String) {
        guard let store, let id = clip.id else { return }
        var revealed = clip
        revealed.text = text
        guard Copier.copy(revealed, plainText: true, imageData: nil) else {
            NSSound.beep()
            return
        }
        try? store.bump(id: id, at: Date())
        hidePanel()
        finishCopy(String(localized: "Copied to Clipboard"))
        panelModel.storeDidChange()
    }

    // MARK: - Panel actions

    func togglePanel() {
        // Behind Settings, the shortcut brings the panel forward (PanelController.toggle).
        if panel?.behindSettings == true { panel?.toggle(); return }
        if panel?.isVisible == true { panel?.hide(reason: "shortcut") } else { showPanel() }
    }

    /// With the panel lock on, the panel opens on its lock screen and asks for Touch ID.
    func showPanel() {
        // Not before setup is finished: there is no history to show yet.
        guard settings.onboardingCompleted else { return }
        let locked = panelNeedsUnlock
        panelModel.setPanelLocked(locked)
        panel?.show()
        if locked { unlockPanel() }
    }

    func hidePanel() { panel?.hide() }

    // MARK: - Panel lock

    private var panelNeedsUnlock: Bool {
        guard settings.lockPanel else { return false }
        if lockRequired { return true }
        let idle = Date().timeIntervalSince(lastPanelUse)
        return settings.lockAfterMinutes == 0 || idle > Double(settings.lockAfterMinutes) * 60
    }

    /// Called when the panel closes: the idle time starts now.
    func panelDidHide() {
        if !panelModel.panelLocked { lastPanelUse = Date() }
    }

    /// Touch ID, then the panel shows the history. Cancel leaves the lock screen.
    func unlockPanel() {
        authenticate(reason: String(localized: "open your clipboard history")) { [weak self] context in
            guard let self, context != nil else { return }
            lockRequired = false
            lastPanelUse = Date()
            panelModel.setPanelLocked(false)
        }
    }

    /// A screen lock, sleep or switch to another user locks the panel at once.
    private func observeLockEvents() {
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lockRequired = true
                if self.settings.lockPanel {
                    self.panelModel.setPanelLocked(true)
                    self.hidePanel()
                }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock),
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock),
        ]
    }

    // MARK: - Pause

    /// Stops recording for a while. Nil minutes: until resumed.
    func pauseRecording(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        pauseTimer?.invalidate()
        pauseTimer = nil
        if let minutes {
            let timer = Timer(timeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeRecording() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pauseTimer = timer
        }
        log.info("Recording paused (\(minutes.map { "\($0) min" } ?? "until resumed", privacy: .public))")
        refreshStatusItem()
    }

    func resumeRecording() {
        pausedUntil = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        log.info("Recording resumed")
        refreshStatusItem()
    }

    /// "Paused until 14:20" or "Paused".
    var pauseDescription: String? {
        guard isPaused, let until = pausedUntil else { return nil }
        let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocale.current))
        return until == .distantFuture ? String(localized: "Recording paused") : String(localized: "Paused until \(time)")
    }

    func copy(_ clip: Clip, plainText: Bool) {
        guard let store, let id = clip.id else { return }
        // List items hold only a text preview. Copy the complete clip.
        let full = (try? store.clip(id: id)) ?? clip
        guard Copier.copy(full, plainText: plainText, imageData: full.kind == .image ? store.imageData(for: full) : nil) else {
            NSSound.beep()
            return
        }
        try? store.bump(id: id, at: Date())
        hidePanel()
        finishCopy(plainText && full.rtf != nil ? String(localized: "Copied as Plain Text") : String(localized: "Copied to Clipboard"))
        panelModel.storeDidChange()
    }

    // MARK: - Several items and drags

    /// Full clips, each image with a file: the screenshot itself, or a temporary PNG.
    private func prepareGroup(_ clips: [Clip]) -> [(clip: Clip, imageFile: URL?)] {
        guard let store else { return [] }
        return clips.compactMap { clip in
            guard let id = clip.id, clip.kind != .secret else { return nil }
            let full = (try? store.clip(id: id)) ?? clip
            guard full.kind == .image else { return (full, nil) }
            if let path = full.revealPaths.first, FileManager.default.fileExists(atPath: path) {
                return (full, URL(fileURLWithPath: path))
            }
            guard let data = store.imageData(for: full) else { return nil }
            do {
                return (full, try ExportFiles.write(data, for: full))
            } catch {
                log.error("Exporting an image failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// ↵ with several items picked.
    func copy(_ clips: [Clip], plainText: Bool) {
        let group = prepareGroup(clips)
        guard !group.isEmpty, Copier.copy(group: group, plainText: plainText) else {
            NSSound.beep()
            return
        }
        bump(group.map(\.clip))
        hidePanel()
        finishCopy(String(localized: "Copied \(group.count.formatted()) Items"))
        panelModel.storeDidChange()
    }

    func dragItems(for clips: [Clip]) -> [DragItem] {
        prepareGroup(clips).flatMap { clip, file in
            let image = DragPreview.image(for: clip, file: file)
            return Copier.groupItems(clip, imageFile: file).map { DragItem(pasteboardItem: $0, image: image) }
        }
    }

    /// The panel stays open while a drag is under way.
    func beginDrag() {
        panel?.holdOpen(.drag)
    }

    /// A drop counts as a use, like a paste, and closes the panel. A cancelled drag leaves it open.
    func finishDrag(_ clips: [Clip], dropped: Bool) {
        panel?.releaseOpen(.drag)
        guard dropped else {
            panel?.refocus()
            return
        }
        bump(clips)
        hidePanel()
        panelModel.storeDidChange()
    }

    private func bump(_ clips: [Clip]) {
        let now = Date()
        for id in clips.compactMap(\.id) { try? store?.bump(id: id, at: now) }
    }

    var terminal: TerminalApp? { TerminalApp.resolve(settings.terminalBundleID) }

    /// ⌘T on a file or folder item: its folder in the chosen terminal.
    func openInTerminal(_ paths: [String]) {
        guard let terminal, let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? paths.first else {
            NSSound.beep()
            return
        }
        hidePanel()
        terminal.open(TerminalApp.folder(for: path)) { [weak self] opened in
            guard !opened else { return }
            self?.log.error("Opening a folder in \(terminal.name, privacy: .public) failed")
            self?.toast.show(String(localized: "\(terminal.name) could not open this folder"),
                             symbol: "exclamationmark.circle.fill", tint: .orange)
        }
    }

    /// Opens Finder with the files selected. Files that no longer exist are skipped.
    func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            NSSound.beep()
            toast.show(String(localized: "The file no longer exists"), symbol: "exclamationmark.circle.fill", tint: .orange)
            return
        }
        hidePanel()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The eye button. The panel stays open while the larger preview is in front.
    func openLargePreview(_ clip: Clip) {
        previewWindow.close()
        panel?.holdOpen(.preview)
        let image = clip.imageFile != nil ? panelModel.image(for: clip) : nil
        previewWindow.show(clip: clip, image: image, terms: panelModel.searchTerms, appearance: settings.panelAppearance,
                           near: panel?.frame, actionTitle: panelModel.returnTitle) { [weak self] in
            self?.previewWindow.close()
            self?.copy(clip, plainText: false)
        }
        // Safety net: if the preview did not come up, the panel must not stay stuck open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.previewWindow.isOpen else { return }
            log.error("Large preview did not open")
            panel?.releaseOpen(.preview)
            panel?.refocus()
        }
    }

    func closeLargePreview() {
        previewWindow.close()
    }

    // MARK: - Snippets

    func makeSnippet(_ clip: Clip, name: String) {
        guard let id = clip.id else { return }
        do {
            try store?.makeSnippet(id: id, name: name)
            toast.show(String(localized: "Saved as Snippet “\(name)”"), symbol: "bookmark.fill")
        } catch {
            showError(String(localized: "The snippet could not be saved"), error)
        }
        panelModel.storeDidChange()
    }

    func renameSnippet(_ clip: Clip, name: String) {
        guard let id = clip.id else { return }
        try? store?.renameSnippet(id: id, name: name)
        panelModel.storeDidChange()
    }

    func removeSnippet(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? store?.removeSnippet(id: id)
        panelModel.storeDidChange()
    }

    /// A new, empty snippet; returns its id for the editor.
    func newSnippet(name: String) -> Int64? {
        do {
            return try store?.newSnippet(name: name).id
        } catch {
            showError(String(localized: "The snippet could not be saved"), error)
            return nil
        }
    }

    func saveSnippetText(id: Int64, _ text: String) {
        do {
            try store?.updateSnippetText(id: id, text)
            toast.show(L("Snippet Saved"), symbol: "bookmark.fill")
        } catch {
            showError(String(localized: "The snippet could not be saved"), error)
        }
        panelModel.storeDidChange()
    }

    /// The editor's result: saved as a new item (so it can be found again), then pasted or copied.
    func useEditedText(_ text: String) {
        ingest(ClipClassifier.textContent(text, rtf: nil), source: ClipSource(bundleID: AppInfo.bundleID, appName: "Trove", url: nil))
        copyText(text, message: L("Copied Edited Text"))
    }

    /// Copies derived text (for example re-indented JSON). The stored item does not change.
    func copyText(_ text: String, message: String) {
        let clip = Clip(id: nil, kind: .text, text: text, rtf: nil, byteSize: 0, contentHash: "",
                        pinned: false, timesCopied: 0, firstCopiedAt: Date(), lastCopiedAt: Date())
        guard Copier.copy(clip, plainText: true, imageData: nil) else { NSSound.beep(); return }
        hidePanel()
        finishCopy(message)
    }

    /// ⌘↵ on an e-mail item: a new message in the default mail app.
    func composeEmail(to addresses: [String]) {
        let joined = addresses.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "mailto:" + joined) else { NSSound.beep(); return }
        hidePanel()
        NSWorkspace.shared.open(url)
    }

    /// ⌘↵ on an image from the clipboard: saves it as a PNG file where the user chooses.
    func saveImage(_ clip: Clip) {
        guard let data = store?.imageData(for: clip) else { NSSound.beep(); return }
        hidePanel()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        let stamp = clip.lastCopiedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        savePanel.nameFieldStringValue = String(localized: "Image \(stamp).png")
        savePanel.canCreateDirectories = true
        NSApp.activate()
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            toast.show(L("Image Saved"))
        } catch {
            showError(String(localized: "The image could not be saved"), error)
        }
    }

    /// ⌘↵ on a link: opens it in the default browser. Only web links (http, https, ftp) become link
    /// items, so this never opens a local file or another app's URL scheme.
    func openLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) else { NSSound.beep(); return }
        hidePanel()
        NSWorkspace.shared.open(url)
    }

    /// ⌘↵ on a phone item: calls through FaceTime or a paired iPhone.
    func call(_ number: String) {
        guard let url = URL(string: "tel:" + number) else { NSSound.beep(); return }
        hidePanel()
        NSWorkspace.shared.open(url)
    }

    func setPinned(_ clip: Clip, _ pinned: Bool) {
        guard let id = clip.id else { return }
        try? store?.setPinned(id: id, pinned)
    }

    func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? store?.delete(id: id)
    }

    // MARK: - Settings window

    /// The app that was in front when Settings opened from the panel. It gets the keyboard back
    /// when Settings closes, so ↵ in the panel pastes there again.
    private var appBeforeSettings: NSRunningApplication?

    func openSettings() {
        if panel?.isVisible == true, panel?.behindSettings == false {
            let front = NSWorkspace.shared.frontmostApplication
            appBeforeSettings = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            panel?.moveBehindSettings()
        }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(app: self)
            settingsWindow?.onClose = { [weak self] in self?.settingsDidClose() }
        }
        refreshUsage()
        settingsWindow?.show()
    }

    /// The panel, if it was open behind Settings, comes back in front of the app it was over.
    private func settingsDidClose() {
        guard panel?.behindSettings == true else { return }
        let previous = appBeforeSettings
        appBeforeSettings = nil
        previous?.activate()
        // After the other app is active again, so the panel keeps the keyboard over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, panel?.returnFromSettings() == true else { return }
            panelModel.refocusSearch()
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Hot key

    private var pauseHotKey: GlobalHotKey?

    struct SameShortcutError: Error, CustomStringConvertible {
        var description: String { L("This shortcut already opens the panel.") }
    }

    func hotKeySetting(_ role: HotKeyRole) -> HotKeySetting? {
        role == .panel ? settings.hotKey : settings.pauseHotKey
    }

    /// Registers the shortcut and saves it. On failure, the previous shortcut stays active.
    /// Nil removes the pause shortcut (the panel always has one).
    func applyHotKey(_ setting: HotKeySetting?, role: HotKeyRole = .panel) throws {
        let other = hotKeySetting(role == .panel ? .pause : .panel)
        if let setting, let other, setting.combo == other.combo { throw SameShortcutError() }
        switch role {
        case .panel:
            guard let hotKey, let setting else { return }
            do {
                try hotKey.register(setting.combo)
                settings.hotKey = setting
                hotKeyError = nil
            } catch {
                try? hotKey.register(settings.hotKey.combo)
                throw error
            }
        case .pause:
            guard let pauseHotKey else { return }
            guard let setting else {
                pauseHotKey.unregister()
                settings.pauseHotKey = nil
                return
            }
            do {
                try pauseHotKey.register(setting.combo)
                settings.pauseHotKey = setting
            } catch {
                if let old = settings.pauseHotKey { try? pauseHotKey.register(old.combo) }
                throw error
            }
        }
    }

    /// Releases the shortcut while the recorder listens for a new one.
    func suspendHotKey(_ role: HotKeyRole = .panel) {
        (role == .panel ? hotKey : pauseHotKey)?.unregister()
    }

    func resumeHotKey(_ role: HotKeyRole = .panel) {
        guard role == .panel else {
            if let combo = settings.pauseHotKey?.combo { try? pauseHotKey?.register(combo) }
            return
        }
        do {
            try hotKey?.register(settings.hotKey.combo)
            hotKeyError = nil
        } catch {
            hotKeyError = String(describing: error)
            log.error("Global shortcut failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The pause shortcut: pauses recording until pressed again, from any app.
    func togglePauseFromShortcut() {
        if isPaused {
            resumeRecording()
            toast.show(L("Recording resumed"), symbol: "record.circle", tint: .green)
        } else {
            pauseRecording(minutes: nil)
            toast.show(L("Recording paused"), symbol: "pause.circle.fill", tint: .orange)
        }
    }

    // MARK: - Launch at login, Dock, menu bar

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        objectWillChange.send()
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private func applyDockIcon(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // Changing the policy can push the settings window behind other apps.
        if settingsWindow?.isVisible == true {
            NSApp.activate()
        }
    }

    private func applyStatusItem(_ show: Bool) {
        if show, statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            refreshStatusItem()
        } else if !show, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            statusActions = []
        }
    }

    /// The menu bar icon and menu, with the pause state.
    private func refreshStatusItem() {
        guard let item = statusItem else { return }
        let paused = isPaused
        item.button?.image = NSImage(systemSymbolName: paused ? "pause.circle" : "list.clipboard",
                                     accessibilityDescription: paused ? String(localized: "Trove, paused") : "Trove")
        item.button?.toolTip = pauseDescription
        let open = MenuAction { [weak self] in self?.showPanel() }
        let prefs = MenuAction { [weak self] in self?.openSettings() }
        let quit = MenuAction { [weak self] in self?.quit() }
        let update = MenuAction { [weak self] in self?.updates?.check() }
        let tour = MenuAction { [weak self] in self?.showTour() }
        let resume = MenuAction { [weak self] in self?.resumeRecording() }
        let pause10 = MenuAction { [weak self] in self?.pauseRecording(minutes: 10) }
        let pause60 = MenuAction { [weak self] in self?.pauseRecording(minutes: 60) }
        let pauseAll = MenuAction { [weak self] in self?.pauseRecording(minutes: nil) }
        statusActions = [open, prefs, quit, resume, pause10, pause60, pauseAll, update, tour]
        let menu = NSMenu()
        menu.addItem(open.item(String(localized: "Open Trove")))
        menu.addItem(.separator())
        if paused {
            let status = NSMenuItem(title: pauseDescription ?? "", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(resume.item(String(localized: "Resume Recording")))
        } else {
            menu.addItem(pause10.item(String(localized: "Pause for 10 Minutes")))
            menu.addItem(pause60.item(String(localized: "Pause for 1 Hour")))
            menu.addItem(pauseAll.item(String(localized: "Pause Until Resumed")))
        }
        menu.addItem(.separator())
        menu.addItem(tour.item(String(localized: "How Trove Works…")))
        menu.addItem(update.item(String(localized: "Check for Updates…")))
        menu.addItem(prefs.item(String(localized: "Settings…"), key: ","))
        menu.addItem(quit.item(String(localized: "Quit Trove"), key: "q"))
        item.menu = menu
    }

    // MARK: - Storage

    var storageSyncProvider: String? {
        StorageLocation.syncProvider(for: storageDirectory)
    }

    private func resolveStorageDirectory() -> URL {
        guard let bookmark = settings.storageBookmark else { return StorageLocation.defaultDirectory }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
           url.startAccessingSecurityScopedResource() {
            scopedDirectory = url
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                settings.storageBookmark = fresh
            }
            return url
        }
        storageWarning = String(localized: "The saved storage folder is not reachable. Trove uses the default folder.")
        log.error("Storage bookmark could not be resolved")
        return StorageLocation.defaultDirectory
    }

    /// Finds the folder's key (Keychain, or the recovery password for a history from another
    /// Mac) and opens the encrypted store. Returns false when no store could be opened.
    @discardableResult
    private func openStore(at directory: URL, quitOnCancel: Bool = false) -> Bool {
        let databaseURL = directory.appendingPathComponent(Store.databaseFileName)
        if Store.isPlaintextDatabase(databaseURL), !confirmEncryption(of: directory, quitOnCancel: quitOnCancel) {
            storageWarning = String(localized: "The history in “\(StorageLocation.displayPath(directory))” is not encrypted yet.")
            return false
        }
        do {
            let key: DataKey
            switch try vault.prepare(directory: directory) {
            case .ready(let found):
                key = found
            case .locked(let file):
                guard let unlocked = askRecoveryPassword(for: file, directory: directory) else {
                    storageWarning = String(localized: "The history in “\(StorageLocation.displayPath(directory))” is locked. Enter its recovery password to use it.")
                    return false
                }
                key = unlocked
            case .unrecoverable:
                showUnrecoverableAlert(directory)
                storageWarning = String(localized: "The history in “\(StorageLocation.displayPath(directory))” is encrypted with a key this Mac does not have.")
                return false
            }
            let opened = try Store.open(directory: directory, key: key)
            store = opened
            dataKey = key
            scheduleExpiry()
            if let backup = opened.unencryptedBackup {
                storageWarning = String(localized: "The unencrypted original of your history is in “\(StorageLocation.displayPath(backup))”. Delete it when you no longer need it.")
            }
            storageDirectory = directory
            hasRecoveryPassword = vault.hasRecoveryPassword(directory: directory)
            textIndexer.stop()
            textIndexer.start() // Images not read yet (new store, or the first run after an update).
            log.info("Store ready at \(directory.path, privacy: .public)")
            return true
        } catch {
            log.error("Store failed to open: \(error.localizedDescription, privacy: .public)")
            storageWarning = String(localized: "The history database could not be opened: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Encryption

    /// Asks before a version 0.1 history is encrypted. Cancel leaves every file as it is.
    private func confirmEncryption(of directory: URL, quitOnCancel: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Encrypt your clipboard history?")
        alert.informativeText = String(localized: """
            Trove now encrypts its history. The history in “\(StorageLocation.displayPath(directory))” is not encrypted yet.

            Trove makes an encrypted copy and checks it. Then the unencrypted original moves to the Trash, \
            so you can still restore it. Empty the Trash to remove it for good. Sync services can keep older, unencrypted versions.
            """)
        alert.addButton(withTitle: String(localized: "Encrypt"))
        alert.addButton(withTitle: quitOnCancel ? String(localized: "Quit Trove") : String(localized: "Cancel"))
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if !confirmed, quitOnCancel {
            NSApp.terminate(nil)
        }
        return confirmed
    }

    /// Asks for the recovery password until it is correct or the user cancels.
    private func askRecoveryPassword(for file: KeyFile, directory: URL) -> DataKey? {
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = String(localized: "Unlock Trove")
            alert.informativeText = (problem.map { $0 + "\n\n" } ?? "") + String(localized: """
                The history in “\(StorageLocation.displayPath(directory))” was encrypted on another Mac, \
                or this Mac’s Keychain no longer has its key. Enter the recovery password to open it here.
                """)
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = String(localized: "Recovery password")
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "Unlock"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = field
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            do {
                let key = try vault.unlock(file, password: field.stringValue)
                log.info("History unlocked with the recovery password")
                return key
            } catch VaultError.wrongPassword {
                problem = String(localized: "The password is not correct.")
            } catch {
                showError(String(localized: "The history could not be unlocked"), error)
                return nil
            }
        }
    }

    private func showUnrecoverableAlert(_ directory: URL) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "This history cannot be opened")
        alert.informativeText = String(localized: """
            The history in “\(StorageLocation.displayPath(directory))” is encrypted, and its key is not in this Mac’s Keychain. \
            It has no recovery password, so it cannot be decrypted here. Choose another folder in Settings.
            """)
        NSApp.activate()
        alert.runModal()
    }

    /// Sets, changes or (with nil) removes the recovery password of the open history.
    func setRecoveryPassword(_ password: String?) throws {
        guard let dataKey else { throw CocoaError(.fileNoSuchFile) }
        try vault.setRecoveryPassword(password, key: dataKey, directory: storageDirectory)
        hasRecoveryPassword = password != nil
        log.info("Recovery password \(password == nil ? "removed" : "set", privacy: .public)")
    }

    /// Asks for a location and creates (or reuses) the "Trove History" folder in it, or uses the
    /// location itself when that is turned off. Existing history moves along. Returns true when a
    /// store is open at the new folder.
    @discardableResult
    func chooseStorageLocation(startingAt start: URL? = nil, message: String? = nil) -> Bool {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = start
        openPanel.prompt = String(localized: "Choose")
        openPanel.message = message ?? (settings.historySubfolder
            ? String(localized: "Trove creates a “\(StorageLocation.historyFolderName)” folder in the location you choose.")
            : String(localized: "Trove saves its files directly in the folder you choose."))
        NSApp.activate()
        guard openPanel.runModal() == .OK, let picked = openPanel.url else { return false }
        return moveStorage(to: StorageLocation.historyFolder(for: picked, subfolder: settings.historySubfolder))
    }

    /// True when the history has its own folder inside the chosen location.
    var usesHistoryFolder: Bool {
        store == nil ? settings.historySubfolder : StorageLocation.isHistoryFolder(storageDirectory)
    }

    /// The "own folder" switch. With a history already open, it moves: into a new "Trove History"
    /// folder in the same place, or up into the chosen location. Going up needs the user's
    /// permission for that folder (sandbox), so a folder dialog opens there, already selected.
    func setUsesHistoryFolder(_ on: Bool) {
        let before = settings.historySubfolder
        settings.historySubfolder = on
        guard store != nil, on != StorageLocation.isHistoryFolder(storageDirectory) else { return }
        let moved: Bool
        if on {
            moved = moveStorage(to: storageDirectory.appendingPathComponent(StorageLocation.historyFolderName, isDirectory: true))
        } else {
            let parent = storageDirectory.deletingLastPathComponent()
            moved = chooseStorageLocation(startingAt: parent, message: String(localized:
                "To save directly in “\(parent.lastPathComponent)”, Trove needs your permission for that folder. Click Choose."))
        }
        if !moved { settings.historySubfolder = before }
    }

    /// Opens (and if needed moves) the history at `url`.
    @discardableResult
    private func moveStorage(to url: URL) -> Bool {
        if store != nil, url.standardizedFileURL == storageDirectory.standardizedFileURL { return true }

        // Asked once per sync service: moving within the same synced folder does not ask again.
        if let provider = StorageLocation.syncProvider(for: url),
           store == nil || StorageLocation.syncProvider(for: storageDirectory) != provider {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "This folder is synced by \(provider)")
            alert.informativeText = String(localized: """
                Trove encrypts the history, so \(provider) receives only unreadable files. \
                To open the history on another Mac, set a recovery password in Settings › Security.

                Use this folder anyway?
                """)
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Use Anyway"))
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }

        let fm = FileManager.default
        let hasExisting = fm.fileExists(atPath: url.appendingPathComponent(Store.databaseFileName).path)
            || fm.fileExists(atPath: KeyFile.url(in: url).path)
        if hasExisting {
            let alert = NSAlert()
            alert.messageText = String(localized: "This folder already has clipboard history")
            alert.informativeText = store == nil
                ? String(localized: "Trove continues with the history in this folder.")
                : String(localized: "Trove switches to the history in this folder. The current history stays in the old folder.")
            alert.addButton(withTitle: String(localized: "Use Existing History"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        let bookmark: Data
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            showError(String(localized: "The folder cannot be used"), error)
            return false
        }
        _ = url.startAccessingSecurityScopedResource()

        let oldDirectory = storageDirectory
        let hadStore = store != nil
        try? store?.close()
        store = nil
        dataKey = nil

        // Before onboarding, earlier history may sit in the default folder. It moves too.
        let oldHasHistory = fm.fileExists(atPath: oldDirectory.appendingPathComponent(Store.databaseFileName).path)
        if !hasExisting, oldHasHistory, oldDirectory.standardizedFileURL != url.standardizedFileURL {
            do {
                try Store.moveFiles(from: oldDirectory, to: url)
                Self.removeIfEmptyHistoryFolder(oldDirectory)
            } catch {
                url.stopAccessingSecurityScopedResource()
                if hadStore { openStore(at: oldDirectory) }
                showError(String(localized: "The history could not be moved"), error)
                return false
            }
        }

        guard openStore(at: url) else {
            url.stopAccessingSecurityScopedResource()
            if hadStore { openStore(at: oldDirectory) }
            return false
        }
        if scopedDirectory != url {
            scopedDirectory?.stopAccessingSecurityScopedResource()
        }
        scopedDirectory = url
        settings.storageBookmark = bookmark
        storageWarning = nil
        refreshUsage()
        panelModel.storeDidChange()
        log.info("Storage folder set to \(url.path, privacy: .public)")
        return true
    }

    /// A history folder left empty by a move goes away, so no empty "Trove History" stays behind.
    /// Anything else in it (the user's own files) keeps it where it is.
    private static func removeIfEmptyHistoryFolder(_ folder: URL) {
        guard StorageLocation.isHistoryFolder(folder) else { return }
        let fm = FileManager.default
        let rest = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]).filter { $0 != ".DS_Store" }
        guard rest.isEmpty else { return }
        try? fm.removeItem(at: folder)
    }

    func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([storageDirectory])
    }

    func refreshUsage() {
        usage = (try? store?.usage()) ?? StoreUsage()
    }

    func clearHistory(since: Date?) {
        do {
            try store?.clear(since: since)
        } catch {
            showError(String(localized: "History could not be cleared"), error)
        }
        refreshUsage()
        panelModel.storeDidChange()
    }

    /// Changes a limit. When the new limit removes items, asks first and shows how many.
    /// Cancel keeps the old value.
    func changeLimits(retentionDays: Int? = nil, maxItems: Int? = nil, maxDiskMB: Int? = nil) {
        let days = retentionDays ?? settings.retentionDays
        let items = maxItems ?? settings.maxItems
        let diskMB = maxDiskMB ?? settings.maxDiskMB
        let limits = PruneLimits(retentionDays: days, maxItems: items, maxBytes: diskMB * 1_048_576)
        let count = (try? store?.pruneCount(limits)) ?? 0
        if count > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            let number = count.formatted()
            alert.messageText = count == 1 ? String(localized: "Delete 1 item?") : String(localized: "Delete \(number) items?")
            alert.informativeText = String(localized: "With the new limit, \(number) of your items go over it and are deleted now, oldest first. Pinned items, snippets and hidden items are kept. This cannot be undone.")
            alert.addButton(withTitle: count == 1 ? String(localized: "Delete Item") : String(localized: "Delete Items"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else {
                settings.objectWillChange.send() // The picker shows the old value again.
                return
            }
        }
        settings.retentionDays = days
        settings.maxItems = items
        settings.maxDiskMB = diskMB
        prune(limits)
    }

    /// How many items "Clear" would delete. Pinned items are not counted.
    func clearableCount(since: Date?) -> Int {
        (try? store?.clearCount(since: since)) ?? 0
    }

    private var currentLimits: PruneLimits {
        PruneLimits(retentionDays: settings.retentionDays, maxItems: settings.maxItems, maxBytes: settings.maxDiskMB * 1_048_576)
    }

    func prune() {
        prune(currentLimits)
    }

    private func prune(_ limits: PruneLimits) {
        guard let store else { return }
        do {
            let removed = try store.prune(limits)
            if removed > 0 {
                log.info("Pruned \(removed) clips")
                panelModel.storeDidChange()
                refreshUsage()
            }
        } catch {
            log.error("Pruning failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Import and export

    struct ExportOptions {
        var format: Transfer.Format = .encrypted
        /// Nil: everything.
        var days: Int?
        var pinnedOnly = false
        var includeImages = true
        var password = ""
    }

    /// Writes the history to a file the user chooses. Hidden items are never included.
    func exportHistory(_ options: ExportOptions) {
        guard let store else { return }
        do {
            let since = options.days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
            let items = try store.exportItems(since: since, pinnedOnly: options.pinnedOnly,
                                              includeImages: options.includeImages && options.format != .csv)
            let data: Data = switch options.format {
            case .encrypted: try Transfer.encrypted(items, password: options.password)
            case .json: try Transfer.json(items)
            case .csv: Transfer.csv(items)
            }
            let savePanel = NSSavePanel()
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
            savePanel.nameFieldStringValue = String(localized: "Trove History \(stamp)") + "." + options.format.fileExtension
            savePanel.canCreateDirectories = true
            NSApp.activate()
            guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
            try data.write(to: url, options: [.atomic])
            let count = items.count.formatted()
            toast.show(String(localized: "Exported \(count) items"))
            log.info("Exported \(items.count) items (\(options.format.rawValue, privacy: .public))")
        } catch {
            showError(L("The history could not be exported"), error)
        }
    }

    /// Reads a Trove export, or Raycast, Maccy or Alfred history, shows what it holds and asks before
    /// saving. Duplicates merge; secrets follow the sensitive content rule.
    private var importWindow: ImportWindowController?
    private var tourWindow: TourWindowController?

    /// "How Trove Works": the onboarding demos again.
    func showTour() {
        hidePanel()
        if tourWindow == nil { tourWindow = TourWindowController(appearance: settings.panelAppearance) }
        tourWindow?.show()
    }

    /// Settings › Storage › Import… and onboarding: the import window (sources, summary, progress).
    func importHistory() {
        guard store != nil else { return }
        if importWindow == nil { importWindow = ImportWindowController(app: self) }
        importWindow?.show()
    }

    /// The import window saved items: the panel and the usage numbers show them.
    func importDidFinish() {
        refreshUsage()
        panelModel.storeDidChange()
    }

    func loadHiddenKeyForImport() -> HiddenKey? {
        loadHiddenKey()
    }

    /// Our classifier decides the kind again, so imported text lands in the right group.
    nonisolated static func importContent(_ item: Transfer.Item) -> CapturedContent? {
        if let files = item.files, !files.isEmpty {
            let paths = files.joined(separator: "\n")
            return CapturedContent(kind: .file, text: paths, byteSize: paths.utf8.count, hash: ClipClassifier.hash("file", paths))
        }
        if let image = item.image {
            return ClipClassifier.imageContent(data: image, maxBytes: 200 * 1_048_576)
        }
        guard let text = item.text, !text.isEmpty else { return nil }
        return ClipClassifier.textContent(text, rtf: item.rtf)
    }

    // MARK: - Ignored apps

    func addExcludedApp() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.application]
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = String(localized: "Ignore")
        NSApp.activate()
        guard openPanel.runModal() == .OK else { return }
        for url in openPanel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !settings.excludedApps.contains(where: { $0.bundleID == bundleID }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            settings.excludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
        }
    }

    func removeExcludedApp(_ app: ExcludedApp) {
        settings.excludedApps.removeAll { $0.bundleID == app.bundleID }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }
}
