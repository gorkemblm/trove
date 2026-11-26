import Foundation

/// Re-indents data for "Copy Formatted" and the preview. The stored item is never changed.
enum Formatting {
    /// Indents JSON with two spaces and keeps the key order (JSONSerialization would sort it).
    /// Nil when the text is not valid JSON.
    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        var out = ""
        out.reserveCapacity(trimmed.count + trimmed.count / 4)
        var depth = 0
        var inString = false
        var escaped = false
        // Whitespace outside strings is dropped below; JSON strings cannot hold raw line breaks.
        let characters = Array(trimmed)
        var index = 0
        func newline() {
            out.append("\n")
            out.append(String(repeating: "  ", count: depth))
        }
        while index < characters.count {
            let c = characters[index]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                index += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // An empty object or array stays on one line.
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == (c == "{" ? "}" : "]") {
                    out.append(c)
                    out.append(characters[next])
                    index = next
                } else {
                    out.append(c)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(": ")
            case _ where c.isWhitespace:
                break
            default:
                out.append(c)
            }
            index += 1
        }
        return out
    }

    /// XML (and property lists) indented by Foundation's XML document. Order and comments stay.
    static func prettyXML(_ text: String) -> String? {
        guard let document = try? XMLDocument(xmlString: text, options: [.nodePreserveAll]) else { return nil }
        return document.xmlString(options: [.nodePrettyPrint, .nodePreserveAll])
    }

    static func pretty(_ text: String, format: ContentDetector.DataFormat) -> String? {
        switch format {
        case .json: prettyJSON(text)
        case .xml, .plist: prettyXML(text)
        default: nil
        }
    }

    /// True when the text is packed on one long line (minified), so the preview reads better
    /// re-indented.
    static func isMinified(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 && !trimmed.contains("\n")
    }

    /// CSV or TSV rows, with quoted fields ("a, b" and "" for a quote). Stops after `limit` rows.
    static func table(_ text: String, separator: Character, limit: Int = 2_000) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { quoted = false; pending = following }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field)
                field = ""
            } else if c == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                if rows.count >= limit { return rows }
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
