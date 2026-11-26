import AppKit
import Carbon.HIToolbox

struct ExcludedApp: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    /// Password managers and keychain tools. Their content is never saved.
    static let defaults: [ExcludedApp] = [
        .init(bundleID: "com.1password.1password", name: "1Password"),
        .init(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        .init(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        .init(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        .init(bundleID: "com.apple.Passwords", name: "Passwords"),
    ]
}

/// What happens to copied secrets (API keys, tokens, private keys, card numbers, IBANs).
enum SensitiveRule: String, CaseIterable, Identifiable, Sendable {
    /// Saved in Hidden, sealed with Touch ID.
    case hide
    /// Saved in Hidden, deleted after one minute.
    case hideOneMinute
    /// Not saved.
    case discard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hide: L("Keep in Hidden")
        case .hideOneMinute: L("Keep in Hidden for 1 minute")
        case .discard: L("Don’t save")
        }
    }
}

/// What ↵ does with the chosen item.
/// Which group the panel shows when it opens.
enum OpeningGroup: String, CaseIterable, Identifiable, Sendable {
    /// The group it showed last time, also after a restart (Hidden opens as All: it is locked).
    case last
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last: L("The group used last")
        case .all: L("All")
        }
    }
}

enum ReturnAction: String, CaseIterable, Identifiable, Sendable {
    /// Copies, then pastes into the app in front (needs Accessibility permission).
    case paste
    /// Only copies; the user pastes with ⌘V.
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: L("Paste into the active app")
        case .copy: L("Copy to the clipboard")
        }
    }
}

/// The app's colours: the panel, Settings, onboarding and the large preview.
/// Dark is the original design; System follows macOS.
enum PanelAppearance: String, CaseIterable, Identifiable, Sendable {
    case dark, light, system

    var id: String { rawValue }

    /// Nil follows macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }

    var title: String {
        switch self {
        case .dark: L("Dark")
        case .light: L("Light")
        case .system: L("System")
        }
    }
}

/// What a global shortcut does.
enum HotKeyRole: Sendable {
    case panel
    case pause
}

struct HotKeySetting: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let `default` = HotKeySetting(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyLabel: "Space")

    var combo: GlobalHotKey.Combo { .init(keyCode: keyCode, modifiers: modifiers) }
    var display: String { GlobalHotKey.symbols(forCarbonModifiers: modifiers) + keyLabel }
    /// "⌥ Space": easier to read in a large field.
    var spacedDisplay: String { GlobalHotKey.symbols(forCarbonModifiers: modifiers) + " " + keyLabel }
}

/// User settings, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let retentionDays = "retentionDays"
        static let maxItems = "maxItems"
        static let maxDiskMB = "maxDiskMB"
        static let maxImageMB = "maxImageMB"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockIcon = "showDockIcon"
        static let recordSourceURL = "recordSourceURL"
        static let sensitiveRule = "sensitiveRule"
        static let panelAppearance = "panelAppearance"
        static let screenshotBookmark = "screenshotBookmark"
        static let screenshotPromptAnswered = "screenshotPromptAnswered"
        static let hiddenGroups = "hiddenSidebarGroups"
        static let returnAction = "returnAction"
        static let terminalBundleID = "terminalBundleID"
        static let recognizeText = "recognizeText"
        static let historySubfolder = "historySubfolder"
        static let openingGroup = "openingGroup"
        static let lastGroup = "lastGroup"
        static let lockPanel = "lockPanel"
        static let lockAfterMinutes = "lockAfterMinutes"
        static let pastePromptAnswered = "pastePromptAnswered"
        static let excludedApps = "excludedApps"
        static let hotKey = "hotKey"
        static let pauseHotKey = "pauseHotKey"
        static let storageBookmark = "storageBookmark"
        static let onboardingCompleted = "onboardingCompleted"
    }

    private let defaults: UserDefaults

    /// 0 means forever.
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Key.retentionDays) } }
    /// 0 means unlimited.
    @Published var maxItems: Int { didSet { defaults.set(maxItems, forKey: Key.maxItems) } }
    /// 0 means unlimited.
    @Published var maxDiskMB: Int { didSet { defaults.set(maxDiskMB, forKey: Key.maxDiskMB) } }
    @Published var maxImageMB: Int { didSet { defaults.set(maxImageMB, forKey: Key.maxImageMB) } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) } }
    @Published var recordSourceURL: Bool { didSet { defaults.set(recordSourceURL, forKey: Key.recordSourceURL) } }
    @Published var panelAppearance: PanelAppearance { didSet { defaults.set(panelAppearance.rawValue, forKey: Key.panelAppearance) } }
    @Published var sensitiveRule: SensitiveRule { didSet { defaults.set(sensitiveRule.rawValue, forKey: Key.sensitiveRule) } }
    @Published var excludedApps: [ExcludedApp] { didSet { save(excludedApps, Key.excludedApps) } }
    @Published var hotKey: HotKeySetting { didSet { save(hotKey, Key.hotKey) } }
    /// Pauses or resumes recording from any app. Nil: no shortcut (the default).
    @Published var pauseHotKey: HotKeySetting? {
        didSet {
            if let pauseHotKey { save(pauseHotKey, Key.pauseHotKey) } else { defaults.removeObject(forKey: Key.pauseHotKey) }
        }
    }
    /// The screenshot folder to watch. Nil: screenshots saved as files are not added.
    @Published var screenshotBookmark: Data? { didSet { defaults.set(screenshotBookmark, forKey: Key.screenshotBookmark) } }
    /// Touch ID (or the Mac password) before the panel shows the history.
    @Published var lockPanel: Bool { didSet { defaults.set(lockPanel, forKey: Key.lockPanel) } }
    /// Minutes without use before the panel locks again. 0: every time it opens.
    @Published var lockAfterMinutes: Int { didSet { defaults.set(lockAfterMinutes, forKey: Key.lockAfterMinutes) } }
    @Published var returnAction: ReturnAction { didSet { defaults.set(returnAction.rawValue, forKey: Key.returnAction) } }
    @Published var openingGroup: OpeningGroup { didSet { defaults.set(openingGroup.rawValue, forKey: Key.openingGroup) } }
    /// The group the panel showed last (ClipCategory raw value).
    @Published var lastGroup: Int { didSet { defaults.set(lastGroup, forKey: Key.lastGroup) } }
    /// Read the text in images (Vision, on this Mac), so search finds them by it.
    @Published var recognizeText: Bool { didSet { defaults.set(recognizeText, forKey: Key.recognizeText) } }
    /// A chosen location gets its own "Trove History" folder. Off: the files go straight into it.
    @Published var historySubfolder: Bool { didSet { defaults.set(historySubfolder, forKey: Key.historySubfolder) } }
    /// The terminal for "Open in Terminal". Nil: the first installed one (see TerminalApp).
    @Published var terminalBundleID: String? { didSet { defaults.set(terminalBundleID, forKey: Key.terminalBundleID) } }
    /// True once the user answered "Paste directly into apps?" (or decided in onboarding).
    @Published var pastePromptAnswered: Bool { didSet { defaults.set(pastePromptAnswered, forKey: Key.pastePromptAnswered) } }
    /// Sidebar groups the user turned off (ClipCategory raw values). Their items still show in All.
    @Published var hiddenGroups: Set<Int> { didSet { save(Array(hiddenGroups).sorted(), Key.hiddenGroups) } }
    /// True once the user answered "Add screenshots to history?" (or decided in onboarding).
    @Published var screenshotPromptAnswered: Bool { didSet { defaults.set(screenshotPromptAnswered, forKey: Key.screenshotPromptAnswered) } }
    @Published var storageBookmark: Data? { didSet { defaults.set(storageBookmark, forKey: Key.storageBookmark) } }
    @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.retentionDays: 30,
            Key.maxItems: 5000,
            Key.maxDiskMB: 1024,
            Key.maxImageMB: 20,
            Key.showMenuBarIcon: false,
            Key.showDockIcon: false,
            Key.recordSourceURL: true,
            Key.recognizeText: true,
            Key.historySubfolder: true,
        ])
        retentionDays = defaults.integer(forKey: Key.retentionDays)
        maxItems = defaults.integer(forKey: Key.maxItems)
        maxDiskMB = defaults.integer(forKey: Key.maxDiskMB)
        maxImageMB = defaults.integer(forKey: Key.maxImageMB)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        recordSourceURL = defaults.bool(forKey: Key.recordSourceURL)
        panelAppearance = defaults.string(forKey: Key.panelAppearance).flatMap(PanelAppearance.init(rawValue:)) ?? .dark
        sensitiveRule = defaults.string(forKey: Key.sensitiveRule).flatMap(SensitiveRule.init(rawValue:)) ?? .hide
        excludedApps = Self.load([ExcludedApp].self, Key.excludedApps, from: defaults) ?? ExcludedApp.defaults
        hotKey = Self.load(HotKeySetting.self, Key.hotKey, from: defaults) ?? .default
        pauseHotKey = Self.load(HotKeySetting.self, Key.pauseHotKey, from: defaults)
        storageBookmark = defaults.data(forKey: Key.storageBookmark)
        screenshotBookmark = defaults.data(forKey: Key.screenshotBookmark)
        screenshotPromptAnswered = defaults.bool(forKey: Key.screenshotPromptAnswered)
        hiddenGroups = Set(Self.load([Int].self, Key.hiddenGroups, from: defaults) ?? [])
        lockPanel = defaults.bool(forKey: Key.lockPanel)
        lockAfterMinutes = defaults.object(forKey: Key.lockAfterMinutes) as? Int ?? 5
        returnAction = defaults.string(forKey: Key.returnAction).flatMap(ReturnAction.init(rawValue:)) ?? .paste
        pastePromptAnswered = defaults.bool(forKey: Key.pastePromptAnswered)
        terminalBundleID = defaults.string(forKey: Key.terminalBundleID)
        recognizeText = defaults.bool(forKey: Key.recognizeText)
        historySubfolder = defaults.bool(forKey: Key.historySubfolder)
        openingGroup = defaults.string(forKey: Key.openingGroup).flatMap(OpeningGroup.init(rawValue:)) ?? .last
        lastGroup = defaults.integer(forKey: Key.lastGroup)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
