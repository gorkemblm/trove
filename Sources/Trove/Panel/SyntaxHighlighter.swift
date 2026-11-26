import AppKit
import SwiftUI

/// Light syntax colouring for code and data previews. Regex based: it colours keys, strings,
/// numbers, keywords, tags and comments; it does not parse. Later rules win over earlier ones,
/// so comments and strings are applied last.
enum SyntaxHighlighter {
    enum Token: CaseIterable {
        case key, string, number, keyword, tag, attribute, comment, added, removed, section

        var color: NSColor {
            switch self {
            case .key, .tag: Self.dynamic(dark: (0.53, 0.75, 1.0), light: (0.05, 0.36, 0.78))
            case .string, .added: Self.dynamic(dark: (0.60, 0.85, 0.55), light: (0.16, 0.50, 0.12))
            case .number, .attribute: Self.dynamic(dark: (0.98, 0.70, 0.42), light: (0.70, 0.36, 0.0))
            case .keyword, .section: Self.dynamic(dark: (0.85, 0.62, 0.98), light: (0.55, 0.18, 0.70))
            case .comment: Self.dynamic(dark: (0.50, 0.50, 0.53), light: (0.52, 0.52, 0.55))
            case .removed: Self.dynamic(dark: (1.0, 0.50, 0.50), light: (0.78, 0.12, 0.12))
            }
        }

        private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }
    }

    /// Text larger than this is shown without colours, so the preview stays fast.
    static let limit = 200_000

    private typealias Rule = (pattern: String, token: Token, group: Int, options: NSRegularExpression.Options)

    private static let jsonRules: [Rule] = [
        (#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, .number, 0, []),
        (#"\b(true|false|null)\b"#, .keyword, 0, []),
        (#""(?:[^"\\]|\\.)*""#, .string, 0, []),
        (#"("(?:[^"\\]|\\.)*")\s*:"#, .key, 1, []),
    ]
    private static let markupRules: [Rule] = [
        (#"</?[A-Za-z_][\w:.\-]*|/?>|<\?xml|\?>"#, .tag, 0, []),
        (#"\s([A-Za-z_][\w:.\-]*)="#, .attribute, 1, []),
        (#""[^"]*"|'[^']*'"#, .string, 0, []),
        (#"<!--[\s\S]*?-->"#, .comment, 0, []),
    ]
    private static let yamlRules: [Rule] = [
        (#"-?\b\d+(\.\d+)?\b"#, .number, 0, []),
        (#"\b(true|false|null|yes|no)\b"#, .keyword, 0, []),
        (#"^(\s*-?\s*)([\w."'/\-]+):"#, .key, 2, [.anchorsMatchLines]),
        (#""(?:[^"\\]|\\.)*"|'[^']*'"#, .string, 0, []),
        (#"(?:^|\s)#.*$"#, .comment, 0, [.anchorsMatchLines]),
    ]
    private static let configRules: [Rule] = [
        (#"-?\b\d+(\.\d+)?\b"#, .number, 0, []),
        (#"\b(true|false)\b"#, .keyword, 0, []),
        (#"^\s*(?:export\s+)?([\w."'\-]+)\s*(?==|:)"#, .key, 1, [.anchorsMatchLines]),
        (#"^\s*\[\[?.*\]\]?\s*$"#, .section, 0, [.anchorsMatchLines]),
        (#""(?:[^"\\]|\\.)*"|'[^']*'"#, .string, 0, []),
        (#"^\s*[#;].*$"#, .comment, 0, [.anchorsMatchLines]),
    ]
    private static let diffRules: [Rule] = [
        (#"^\+.*$"#, .added, 0, [.anchorsMatchLines]),
        (#"^-.*$"#, .removed, 0, [.anchorsMatchLines]),
        (#"^(@@.*@@|diff --git.*|index .*|\+\+\+ .*|--- .*)$"#, .key, 0, [.anchorsMatchLines]),
    ]
    private static let keywords = [
        "func", "let", "var", "const", "if", "else", "for", "while", "return", "class", "struct", "enum", "import",
        "from", "def", "fn", "pub", "public", "private", "static", "async", "await", "try", "catch", "throw", "throws",
        "new", "true", "false", "nil", "null", "None", "True", "False", "self", "this", "switch", "case", "break",
        "continue", "in", "of", "interface", "type", "extends", "implements", "package", "use", "impl", "match",
        "where", "guard", "defer", "do", "export", "default", "function", "lambda", "yield", "elif", "and", "or",
        "not", "protocol", "extension", "override", "final", "mut", "go", "chan", "select",
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "SET", "DELETE", "JOIN", "LEFT", "RIGHT", "INNER",
        "ON", "AND", "OR", "NOT", "AS", "ORDER", "BY", "GROUP", "LIMIT", "VALUES", "CREATE", "TABLE", "ALTER",
        "DROP", "INDEX", "PRIMARY", "KEY", "NULL", "IS", "IN", "WITH", "UNION", "DISTINCT", "HAVING",
        "FROM", "RUN", "COPY", "CMD", "ENV", "WORKDIR", "EXPOSE", "ENTRYPOINT", "ARG",
    ]
    private static let codeRules: [Rule] = [
        (#"\b\d+(\.\d+)?\b"#, .number, 0, []),
        (#"\b("# + keywords.joined(separator: "|") + #")\b"#, .keyword, 0, []),
        (#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`"#, .string, 0, []),
        (#"//.*$|(?:^|\s)#(?![0-9A-Fa-f]{3,8}\b).*$|--\s.*$"#, .comment, 0, [.anchorsMatchLines]),
        (#"/\*[\s\S]*?\*/"#, .comment, 0, []),
    ]

    private static let compiled: [String: [(NSRegularExpression, Token, Int)]] = {
        var result: [String: [(NSRegularExpression, Token, Int)]] = [:]
        for (name, rules) in [("json", jsonRules), ("markup", markupRules), ("yaml", yamlRules), ("config", configRules),
                              ("diff", diffRules), ("code", codeRules)] {
            result[name] = rules.map { (try! NSRegularExpression(pattern: $0.pattern, options: $0.options), $0.token, $0.group) }
        }
        return result
    }()

    /// The rule set for a clip: by data format, or by code language.
    static func ruleSet(kind: ClipKind, format: String?) -> String? {
        switch kind {
        case .data:
            switch ContentDetector.DataFormat(rawValue: format ?? "") {
            case .json, .jsonLines: return "json"
            case .xml, .plist: return "markup"
            case .yaml: return "yaml"
            case .toml, .ini, .env: return "config"
            case .csv, .tsv, nil: return nil
            }
        case .code:
            switch format {
            case "JSON": return "json"
            case "HTML", "XML", "SVG": return "markup"
            case "Diff": return "diff"
            default: return "code"
            }
        default:
            return nil
        }
    }

    static func spans(_ text: String, ruleSet: String) -> [(NSRange, Token)] {
        guard text.utf16.count <= limit, let rules = compiled[ruleSet] else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        var result: [(NSRange, Token)] = []
        for (regex, token, group) in rules {
            for match in regex.matches(in: text, range: range) {
                let r = match.range(at: group)
                if r.location != NSNotFound, r.length > 0 { result.append((r, token)) }
            }
        }
        return result
    }

    /// For SwiftUI previews.
    static func attributed(_ text: String, ruleSet: String?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let ruleSet else { return attributed }
        for (range, token) in spans(text, ruleSet: ruleSet) {
            guard let swiftRange = Range(range, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = Color(nsColor: token.color)
        }
        return attributed
    }

    /// For the large preview (NSTextView handles long text better than SwiftUI Text).
    static func nsAttributed(_ text: String, ruleSet: String?, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard let ruleSet else { return result }
        for (range, token) in spans(text, ruleSet: ruleSet) {
            result.addAttribute(.foregroundColor, value: token.color, range: range)
        }
        return result
    }
}
