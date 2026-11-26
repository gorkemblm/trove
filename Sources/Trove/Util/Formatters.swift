import AppKit

enum Formatters {
    /// "now", "4m", "3h", "2d".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3600 { let value = String(seconds / 60); return String(localized: "\(value)m") }
        if seconds < 86_400 { let value = String(seconds / 3600); return String(localized: "\(value)h") }
        let value = String(seconds / 86_400)
        return String(localized: "\(value)d")
    }

    /// "Today at 17:36:20", "Yesterday at 09:12:04", "21 Nov 2026 at 16:18:09".
    @MainActor
    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    @MainActor
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.current
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

extension String {
    /// Nil for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension String {
    /// Lower case, without accents, and the Turkish letters as plain ones (ı İ → i, ş → s,
    /// ğ → g, ç → c, ö → o, ü → u): "Yılmaz" and "YILMAZ" both become "yilmaz". Vision reads
    /// Turkish text without its letters, and people type it both ways.
    var searchFolded: String {
        replacingOccurrences(of: "İ", with: "i").replacingOccurrences(of: "I", with: "i")
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
