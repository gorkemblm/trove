import AppKit

/// The app's language: macOS's choice (System), English or Turkish.
///
/// Uses the standard per-app language of macOS (the AppleLanguages setting in this app's own
/// preferences, the same one System Settings › General › Language & Region › Applications
/// writes). macOS applies it at launch, so a change needs a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// Each language in its own name, so it is readable whatever the current language is.
    var title: String {
        switch self {
        case .system: L("System")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice saved for this app (not the macOS-wide list).
    static var saved: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: AppInfo.bundleID) ?? [:]
        guard let first = (domain[key] as? [String])?.first else { return .system }
        return first.hasPrefix("tr") ? .turkish : .english
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// The choice when this copy of the app started. A different saved choice needs a restart.
    static let atLaunch = saved

    /// The language the running app uses (it changes only after a restart).
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }
}

/// The translation of a key that is only known at run time, such as a detector reason saved in
/// the database ("GitHub token"). Literal text in SwiftUI views is translated by SwiftUI itself.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

enum AppLocale {
    /// Dates and numbers follow the app's language, not only the region.
    static var current: Locale {
        let language = AppLanguage.running
        let region = Locale.current.region?.identifier
        return Locale(identifier: region.map { "\(language)_\($0)" } ?? language)
    }
}

extension NSApplication {
    /// Starts a new copy of Clipboard and quits this one (for a language change).
    @MainActor
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
