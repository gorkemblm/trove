import UniformTypeIdentifiers
import Foundation
import GRDB

enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, link, image, file, color
    /// Kinds of text, shown under Text: source code or a command, e-mail addresses, a phone number.
    case code, email, phone
    /// Structured data: JSON, XML, YAML, CSV and similar. `format` names it.
    case data
    /// A detected secret. `text` holds only a masked form; the content is in `sealed`.
    case secret

    var title: String {
        switch self {
        case .text: L("Text")
        case .link: L("Link")
        case .image: L("Image")
        case .file: L("File")
        case .color: L("Color")
        case .code: L("Code")
        case .email: L("Email")
        case .phone: L("Phone")
        case .data: L("Data")
        case .secret: L("Hidden")
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .email: "envelope"
        case .phone: "phone"
        case .data: "curlybraces"
        case .secret: "key"
        }
    }

    /// Kinds that hold text the user copied (secret detection runs on these).
    var isTextual: Bool {
        switch self {
        case .text, .link, .color, .code, .email, .phone, .data: true
        case .image, .file, .secret: false
        }
    }
}

struct Clip: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip"

    var id: Int64?
    var kind: ClipKind
    /// Text, link, colour value, or file paths separated by newlines.
    var text: String?
    var rtf: Data?
    /// File name inside the store's Images folder.
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    /// Total size of copied files, when the sandbox lets the app read it.
    var fileSize: Int?
    /// Bytes this clip uses in the store.
    var byteSize: Int
    var contentHash: String
    var sourceBundleID: String?
    var sourceAppName: String?
    var sourceURL: String?
    var pinned: Bool
    var timesCopied: Int
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    /// Text statistics, computed once when the clip is saved. The list loads only a text
    /// preview, so the counts cannot come from `text` there.
    var textCharacters: Int? = nil
    var textWords: Int? = nil
    var textLines: Int? = nil
    /// The part of the content that search and the list read: the first 20,000 characters.
    /// Large texts stay out of every list and search query; only copy and the detail view read `text`.
    var searchText: String? = nil
    /// Hidden items only: what was detected ("GitHub token"), the content sealed to the
    /// hidden key, and the time the item deletes itself (nil: kept).
    var secretReason: String? = nil
    var sealed: Data? = nil
    var expiresAt: Date? = nil
    /// Code: the language guess ("Swift"). Data: the format ("JSON").
    var format: String? = nil
    /// Images: the text Vision found in the picture, for search and "Copy Text". Nil: not read
    /// yet; empty: read, no text. List queries do not load it.
    var recognizedText: String? = nil
    /// The same text line by line, with each line's place in the image (RecognizedText as JSON).
    var recognizedLayout: String? = nil
    /// The same text folded (`searchFolded`) for the search index: "Yılmaz" finds "Yilmaz".
    var recognizedSearch: String? = nil
    /// Snippets: the name ("Home address"). Snippets are kept like pinned items and never
    /// pruned; search finds them by name and content.
    var snippetName: String? = nil

    var isSnippet: Bool { snippetName != nil }

    var rowID: Int64 { id ?? -1 }

    nonisolated static let searchCharacters = 20_000

    /// Fills the derived columns from the full content. Call before insert.
    mutating func prepareDerivedFields() {
        switch kind {
        case .text, .code, .data:
            guard let text else { return }
            searchText = String(text.prefix(Self.searchCharacters))
            if let snippetName { searchText = snippetName + "\n" + (searchText ?? "") }
            textCharacters = text.count
            textWords = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            textLines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        case .link, .color, .file, .email, .phone:
            searchText = snippetName.map { $0 + "\n" + (text ?? "") } ?? text
        case .image:
            // Screenshots keep their file path in `text`; search finds them by file name.
            searchText = text.map { ($0 as NSString).lastPathComponent }
        case .secret:
            // Search finds hidden items by type, name and masked form, never by content.
            searchText = Store.secretSearchText(reason: secretReason, name: format, masked: text)
        }
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Derived values for display

extension Clip {
    /// The source of screenshots added from the screenshot folder.
    static let screenshotSource = "com.apple.screenshot.launcher"

    /// `format` of a file item whose files are all images: it also shows in Images.
    static let imageFilesFormat = "image"

    static func areImageFiles(_ paths: [String]) -> Bool {
        !paths.isEmpty && paths.allSatisfy { path in
            let ext = (path as NSString).pathExtension
            return !ext.isEmpty && (UTType(filenameExtension: ext)?.conforms(to: .image) ?? false)
        }
    }

    var isImageFiles: Bool { kind == .file && format == Self.imageFilesFormat }

    var filePaths: [String] {
        guard kind == .file, let text else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Files that "Show in Finder" selects: the saved screenshot, or the copied files.
    /// Needs the full clip (`text` in list items holds only the file name).
    var revealPaths: [String] {
        switch kind {
        case .image: text.map { $0.hasPrefix("/") ? [$0] : [] } ?? []
        case .file: filePaths
        default: []
        }
    }

    /// A snippet shows its name; everything else its content.
    var title: String { snippetName ?? contentTitle }

    /// The one-line form of the content, whatever the item's name is.
    var contentTitle: String {
        switch kind {
        case .text, .code, .data:
            let head = (text ?? "").prefix(1000)
            let line = head.split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            // Spreadsheet rows: show the cells apart.
            let cells = kind == .data ? line.replacingOccurrences(of: "\t", with: " · ") : line
            return String(cells.prefix(300))
        case .link, .color, .phone:
            return text ?? ""
        case .email:
            return (text ?? "").split(whereSeparator: { ",;\n".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        case .secret:
            // The name the user gave it, or the masked form.
            return format ?? text ?? L("Hidden item")
        case .image:
            if let text, !text.isEmpty {
                return ((text as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            return sourceAppName.map { String(localized: "Image (\($0))") } ?? L("Image")
        case .file:
            let paths = filePaths
            let name = paths.first.map { ($0 as NSString).lastPathComponent } ?? L("File")
            let more = (paths.count - 1).formatted()
            return paths.count > 1 ? String(localized: "\(name) and \(more) more") : name
        }
    }

    var subtitle: String {
        // A snippet's name is its title; the line under it shows the start of its content.
        if isSnippet {
            let body = (searchText ?? text ?? "").split(separator: "\n", maxSplits: 1).dropFirst().first ?? Substring(text ?? "")
            let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? L("Empty snippet") : String(line.prefix(200))
        }
        var parts: [String] = []
        if let sourceAppName { parts.append(sourceAppName) }
        switch kind {
        case .image:
            if let imageWidth, let imageHeight { parts.append("\(imageWidth) × \(imageHeight)") }
        case .file:
            let count = filePaths.count
            let number = count.formatted()
            parts.append(count == 1 ? L("1 file") : String(localized: "\(number) files"))
        case .code, .data:
            parts.append(format.map(L) ?? kind.title)
        case .text, .link, .color, .email, .phone:
            parts.append(kind.title)
        case .secret:
            parts.append(secretReason.map(L) ?? kind.title)
            // A named item still shows its masked form ("ghp_…a1B2"), unless it is fully masked.
            if format != nil, let text, text != Store.fullMask { parts.append(text) }
        }
        parts.append(Formatters.relative(lastCopiedAt))
        return parts.joined(separator: " · ")
    }

    var characterCount: Int { textCharacters ?? text?.count ?? 0 }
    var wordCount: Int { textWords ?? 0 }
    var lineCount: Int { textLines ?? 0 }

    var linkURL: URL? {
        guard kind == .link, let text else { return nil }
        if text.lowercased().hasPrefix("www.") { return URL(string: "https://" + text) }
        return URL(string: text)
    }

    var domain: String? { linkURL?.host() }

    var sourceHost: String? {
        sourceURL.flatMap { URL(string: $0)?.host() }
    }

    var rgba: RGBA? {
        guard kind == .color, let text else { return nil }
        return RGBA(parsing: text)
    }
}

struct RGBA: Equatable, Sendable {
    var r: Int, g: Int, b: Int
    var a: Double

    init(r: Int, g: Int, b: Int, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb(…)` and `rgba(…)`.
    init?(parsing value: String) {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                self.init(r: Int(v >> 16 & 0xFF), g: Int(v >> 8 & 0xFF), b: Int(v & 0xFF))
            } else {
                self.init(r: Int(v >> 24 & 0xFF), g: Int(v >> 16 & 0xFF), b: Int(v >> 8 & 0xFF), a: Double(v & 0xFF) / 255)
            }
            return
        }
        let lower = s.lowercased()
        guard lower.hasPrefix("rgb"), let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        let parts = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4,
              let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]),
              [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
        let a = parts.count == 4 ? Double(parts[3]) ?? 1 : 1
        self.init(r: r, g: g, b: b, a: a)
    }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    var rgbString: String { a < 1 ? "rgba(\(r), \(g), \(b), \(a))" : "rgb(\(r), \(g), \(b))" }

    /// "hsl(15, 63%, 60%)", the CSS form; with transparency "hsla(…)".
    var hslString: String {
        let red = Double(r) / 255, green = Double(g) / 255, blue = Double(b) / 255
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        let delta = high - low
        var hue = 0.0
        var saturation = 0.0
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            switch high {
            case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            case green: hue = (blue - red) / delta + 2
            default: hue = (red - green) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let h = Int(hue.rounded()) % 360, s = Int((saturation * 100).rounded()), l = Int((lightness * 100).rounded())
        return a < 1 ? "hsla(\(h), \(s)%, \(l)%, \(a))" : "hsl(\(h), \(s)%, \(l)%)"
    }

    /// The forms "copy as" offers.
    var formats: [(name: String, value: String)] { [("HEX", hex), ("RGB", rgbString), ("HSL", hslString)] }
}
