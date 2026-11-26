import Foundation

/// The changes the editor (⌘E) offers. Each one works on the whole text and returns nil when it
/// does not apply (Base64 that is not Base64, JSON that is not JSON).
enum TextTransform: String, CaseIterable, Identifiable, Sendable {
    case uppercase, lowercase, titleCase, sentenceCase
    case trimLines, collapseSpaces, removeEmptyLines
    case sortLines, removeDuplicateLines, reverseLines
    case urlEncode, urlDecode, base64Encode, base64Decode
    case jsonPretty, jsonMinify

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case caseChange, whitespace, lines, encoding, json
        var id: String { rawValue }

        var title: String {
            switch self {
            case .caseChange: L("Case")
            case .whitespace: L("Clean Up")
            case .lines: L("Lines")
            case .encoding: L("Encode")
            case .json: "JSON"
            }
        }

        var symbol: String {
            switch self {
            case .caseChange: "textformat"
            case .whitespace: "eraser"
            case .lines: "list.bullet"
            case .encoding: "lock.open.display"
            case .json: "curlybraces"
            }
        }

        var transforms: [TextTransform] { TextTransform.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .uppercase, .lowercase, .titleCase, .sentenceCase: .caseChange
        case .trimLines, .collapseSpaces, .removeEmptyLines: .whitespace
        case .sortLines, .removeDuplicateLines, .reverseLines: .lines
        case .urlEncode, .urlDecode, .base64Encode, .base64Decode: .encoding
        case .jsonPretty, .jsonMinify: .json
        }
    }

    var title: String {
        switch self {
        case .uppercase: L("UPPERCASE")
        case .lowercase: L("lowercase")
        case .titleCase: L("Title Case")
        case .sentenceCase: L("Sentence case")
        case .trimLines: L("Trim Spaces at Line Ends")
        case .collapseSpaces: L("Collapse Repeated Spaces")
        case .removeEmptyLines: L("Remove Empty Lines")
        case .sortLines: L("Sort Lines A–Z")
        case .removeDuplicateLines: L("Remove Duplicate Lines")
        case .reverseLines: L("Reverse Line Order")
        case .urlEncode: L("URL Encode")
        case .urlDecode: L("URL Decode")
        case .base64Encode: L("Base64 Encode")
        case .base64Decode: L("Base64 Decode")
        case .jsonPretty: L("Format JSON")
        case .jsonMinify: L("Minify JSON")
        }
    }

    /// Case changes follow the app's language: Turkish "i" becomes "İ".
    func apply(_ text: String, locale: Locale = AppLocale.current) -> String? {
        let lines = text.components(separatedBy: "\n")
        switch self {
        case .uppercase: return text.uppercased(with: locale)
        case .lowercase: return text.lowercased(with: locale)
        case .titleCase: return text.capitalized(with: locale)
        case .sentenceCase:
            let lower = text.lowercased(with: locale)
            var result = ""
            var capitalizeNext = true
            for character in lower {
                if capitalizeNext, character.isLetter {
                    result += String(character).uppercased(with: locale)
                    capitalizeNext = false
                } else {
                    result.append(character)
                    if ".!?\n".contains(character) { capitalizeNext = true }
                }
            }
            return result
        case .trimLines:
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseSpaces:
            return text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        case .removeEmptyLines:
            return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .sortLines:
            return lines.sorted { $0.compare($1, options: [.caseInsensitive, .numeric], locale: locale) == .orderedAscending }
                .joined(separator: "\n")
        case .removeDuplicateLines:
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .reverseLines: return lines.reversed().joined(separator: "\n")
        case .urlEncode:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: allowed)
        case .urlDecode: return text.removingPercentEncoding
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            let compact = text.filter { !$0.isWhitespace }
            let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
            return Data(base64Encoded: padded).flatMap { String(data: $0, encoding: .utf8) }
        case .jsonPretty: return Formatting.prettyJSON(text)
        case .jsonMinify:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let compact = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .fragmentsAllowed])
            else { return nil }
            return String(data: compact, encoding: .utf8)
        }
    }
}
