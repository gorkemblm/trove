import Foundation

/// Recognises e-mail addresses, phone numbers and code in copied text.
///
/// Precision comes first: a type is given only when the whole text is of that type. A paragraph
/// that contains an address stays text. A wrong guess never loses anything: the item only shows
/// under another sub-group of Text.
enum ContentDetector {
    // MARK: - E-mail

    private static let emailPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$"#
    )

    /// One address, or a list separated by commas, semicolons or new lines ("mailto:" allowed).
    static func emailAddresses(in text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), trimmed.count <= 2_000 else { return nil }
        let parts = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased().hasPrefix("mailto:") ? String($0.dropFirst(7)) : $0 }
        guard (1...50).contains(parts.count) else { return nil }
        for part in parts {
            let range = NSRange(part.startIndex..., in: part)
            guard emailPattern.firstMatch(in: part, range: range) != nil else { return nil }
        }
        return parts
    }

    // MARK: - Phone

    private static let phoneDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    private static let datePattern = try! NSRegularExpression(pattern: #"^\d{1,4}[./\-]\d{1,2}[./\-]\d{1,4}$"#)

    /// The number in a dialable form ("+90 532 123 45 67" → "+905321234567"), or nil.
    static func phoneNumber(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (7...32).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || " +-().".contains($0)) }) else { return nil }
        let digits = trimmed.filter(\.isNumber)
        // Copied numbers come with an area or country code. Shorter ones are mostly codes and IDs.
        guard (9...15).contains(digits.count) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard datePattern.firstMatch(in: trimmed, range: range) == nil else { return nil } // 2026-11-25
        // Bare digits are often codes or IDs. Without formatting, accept only national (0…) numbers.
        let formatted = trimmed.contains(where: { " +-().".contains($0) })
        guard formatted || (digits.hasPrefix("0") && (10...11).contains(digits.count)) else { return nil }
        if trimmed.contains("+"), !trimmed.hasPrefix("+") { return nil }
        // Apple's detector must agree, and its match must cover the whole text.
        guard let match = phoneDetector.firstMatch(in: trimmed, range: range), match.range == range else { return nil }
        return (trimmed.hasPrefix("+") ? "+" : "") + digits
    }

    // MARK: - Data formats

    /// Structured data, shown in the Data sub-group. JSON, XML and property lists are checked
    /// with Foundation's parsers; the others with strict line rules.
    enum DataFormat: String, CaseIterable, Sendable {
        case json = "JSON"
        case jsonLines = "JSON Lines"
        case xml = "XML"
        case plist = "Property List"
        case yaml = "YAML"
        case toml = "TOML"
        case ini = "INI"
        case env = ".env"
        case csv = "CSV"
        case tsv = "TSV"

        /// Formats that "Copy Formatted" can re-indent.
        var canPrettyPrint: Bool { self == .json || self == .xml || self == .plist }
    }

    private static let htmlRoots: Set<String> = [
        "html", "head", "body", "div", "span", "p", "a", "ul", "ol", "li", "table", "tr", "td", "th", "section",
        "article", "header", "footer", "nav", "main", "form", "input", "button", "img", "h1", "h2", "h3", "h4",
        "h5", "h6", "br", "hr", "strong", "em", "b", "i", "label", "select", "option", "textarea", "svg", "template",
    ]

    static func dataFormat(of text: String) -> DataFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        if isJSON(trimmed) { return .json }
        if let first = trimmed.first, first == "<" {
            if trimmed.contains("<plist"), let data = trimmed.data(using: .utf8),
               (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil { return .plist }
            if let root = markupRoot(trimmed), !htmlRoots.contains(root.lowercased()),
               trimmed.count <= 1_000_000, let data = trimmed.data(using: .utf8), XMLParser(data: data).parse() {
                return .xml
            }
            return nil
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true).prefix(2_000)
            .map { String($0).replacingOccurrences(of: "\r", with: "") }
        if isJSONLines(lines) { return .jsonLines }
        if let table = delimitedFormat(lines) { return table }
        if isEnv(lines) { return .env }
        if let config = sectionedConfig(lines) { return config }
        if isYAML(lines, documentStart: trimmed.hasPrefix("---")) { return .yaml }
        return nil
    }

    /// The name of the first element, after any XML declaration, comments and doctype.
    private static func markupRoot(_ text: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"^(?:<\?[^>]*\?>\s*|<!--[\s\S]*?-->\s*|<!DOCTYPE[^>]*>\s*)*<([A-Za-z_][\w:.\-]*)"#, options: [.caseInsensitive])
        let head = String(text.prefix(4_000))
        guard let match = pattern.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let range = Range(match.range(at: 1), in: head) else { return nil }
        return String(head[range])
    }

    private static func isJSONLines(_ lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }
        return lines.allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        }
    }

    /// CSV, TSV, or semicolon-separated (Excel in many locales): every line has the same number
    /// of separators outside quotes. Copied spreadsheet cells are TSV.
    private static func delimitedFormat(_ lines: [String]) -> DataFormat? {
        guard !lines.isEmpty, lines.count <= 2_000 else { return nil }
        for (separator, format) in [("\t", DataFormat.tsv), (",", .csv), (";", .csv)] as [(Character, DataFormat)] {
            let counts = lines.map { separatorCount($0, separator) }
            guard let columns = counts.first, columns >= 1, counts.allSatisfy({ $0 == columns }) else { continue }
            if format == .tsv {
                if lines.count >= 2 || columns >= 2 { return .tsv }
                continue
            }
            // Commas also appear in prose: ask for short fields and enough rows or columns.
            let fields = lines.flatMap { $0.split(separator: separator, omittingEmptySubsequences: false) }
            let average = fields.map(\.count).reduce(0, +) / max(fields.count, 1)
            let sentences = fields.filter { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").count > 6 }.count
            guard average <= 40, sentences * 5 <= fields.count else { continue }
            if lines.count >= 3 || (lines.count == 2 && columns >= 2) { return .csv }
        }
        return nil
    }

    private static func separatorCount(_ line: String, _ separator: Character) -> Int {
        var count = 0
        var quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() } else if character == separator, !quoted { count += 1 }
        }
        return count
    }

    private static let envLine = try! NSRegularExpression(pattern: #"^(export )?[A-Z_][A-Z0-9_]*=\S*.*$"#)

    private static func isEnv(_ lines: [String]) -> Bool {
        let content = lines.filter { !$0.hasPrefix("#") }
        guard content.count >= 2 else { return false }
        let matching = content.filter { matches(envLine, $0.trimmingCharacters(in: .whitespaces)) }.count
        return Double(matching) / Double(content.count) >= 0.85
    }

    private static let sectionLine = try! NSRegularExpression(pattern: #"^\[\[?[A-Za-z0-9_.\-" ']+\]\]?$"#)
    private static let tomlValueLine = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9_.\-"']+\s*=\s*("[^"]*"|'[^']*'|-?\d[\d_.:\-TZ+]*|true|false|\[.*\]?|\{.*\}?|""".*)\s*(#.*)?$"#
    )
    private static let iniValueLine = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.\-]+\s*[=:]\s*.*$"#)

    /// TOML when values are typed (quoted strings, numbers, booleans, arrays); INI otherwise.
    private static func sectionedConfig(_ lines: [String]) -> DataFormat? {
        let content = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix(";") }
        guard content.count >= 2 else { return nil }
        let sections = content.filter { matches(sectionLine, $0) }.count
        let toml = content.filter { matches(tomlValueLine, $0) }.count
        let ini = content.filter { matches(iniValueLine, $0) }.count
        if Double(sections + toml) / Double(content.count) >= 0.85, sections >= 1 || toml >= 3 { return .toml }
        if sections >= 1, Double(sections + ini) / Double(content.count) >= 0.85, ini >= 1 { return .ini }
        return nil
    }

    private static let yamlKeyLine = try! NSRegularExpression(pattern: #"^(\s*)(- )?([A-Za-z0-9_.\-"'/]+):(\s+\S.*)?$"#)
    private static let yamlListLine = try! NSRegularExpression(pattern: #"^\s*- \S"#)

    /// YAML needs more than "Name: value" lines, which notes also have: ASCII keys, mostly in
    /// lower or camel case, and nesting (or a "---" start).
    private static func isYAML(_ lines: [String], documentStart: Bool) -> Bool {
        let content = lines.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed != "---" && trimmed != "..."
        }
        guard content.count >= 3 else { return false }
        var keyLines = 0
        var lowerKeys = 0
        var nested = false
        var previousIndent = -1
        var previousOpened = false
        for line in content {
            let indent = line.prefix(while: { $0 == " " }).count
            if previousOpened, indent > previousIndent { nested = true }
            if let match = yamlKeyLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let keyRange = Range(match.range(at: 3), in: line) {
                keyLines += 1
                if line[keyRange].first.map({ $0.isLowercase || $0.isNumber }) == true { lowerKeys += 1 }
                previousOpened = match.range(at: 4).location == NSNotFound
            } else if matches(yamlListLine, line) {
                previousOpened = false
            } else {
                return false
            }
            previousIndent = indent
        }
        guard keyLines >= 2, lowerKeys * 2 >= keyLines else { return false }
        return nested || documentStart
    }

    // MARK: - Markdown

    private static let markdownSignals: [NSRegularExpression] = [
        #"(?m)^#{1,6} \S"#, #"(?m)^```"#, #"\[[^\]]+\]\([^)]+\)"#, #"(?m)^\|.*\|\s*$"#, #"\*\*[^*]+\*\*"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Markdown stays text; the details show it as the format.
    static func isMarkdown(_ text: String) -> Bool {
        let sample = String(text.prefix(20_000))
        guard sample.contains("\n") else { return false }
        return markdownSignals.filter { matches($0, sample) }.count >= 2
            || matches(markdownSignals[0], sample) && sample.split(separator: "\n").count >= 3
    }

    // MARK: - Code

    /// Commands that are almost never ordinary words. "git" is Turkish for "go", so git needs
    /// one of its own subcommands.
    private static let strongCommands: Set<String> = [
        "npm", "npx", "yarn", "pnpm", "bun", "brew", "docker", "kubectl", "curl", "wget", "sudo", "ssh", "scp",
        "rsync", "pip", "pip3", "python3", "swiftc", "xcrun", "xcodebuild", "cargo", "rustc", "terraform", "gcloud",
        "aws", "helm", "ffmpeg", "launchctl", "codesign", "psql", "sqlite3", "redis-cli", "mvn", "gradle",
        "dotnet", "deno", "pod", "composer", "kubectx", "minikube", "podman",
    ]
    private static let gitSubcommands: Set<String> = [
        "status", "add", "commit", "push", "pull", "clone", "checkout", "switch", "branch", "merge", "rebase", "log",
        "diff", "stash", "fetch", "reset", "restore", "tag", "init", "remote", "show", "cherry-pick", "config", "rm",
        "mv", "blame", "bisect", "worktree", "submodule", "revert", "clean", "apply", "reflog", "lfs", "-c", "--version",
    ]
    /// Commands that are also words ("open", "make", "find"): they count only with a flag, a path
    /// or shell syntax after them.
    private static let ambiguousCommands: Set<String> = [
        "cd", "ls", "cat", "open", "make", "find", "touch", "go", "head", "tail", "export", "rm", "mv", "cp", "grep",
        "sed", "awk", "tar", "jq", "vim", "nano", "java", "javac", "node", "python", "swift", "chmod", "chown",
        "mkdir", "defaults", "gem", "bundle", "rails", "php", "xargs", "ansible", "mysql", "echo", "source", "kill",
    ]

    /// Line patterns that only code has. Case-sensitive on purpose: "Let me know" is not `let x = 1`.
    private static let keywordPatterns: [NSRegularExpression] = [
        #"^(let|var|const|val) [A-Za-z_$][\w$]*\s*(:[^=]+)?=\s*\S"#,
        #"^(func|function|def|fn|fun) [A-Za-z_$][\w$]*\s*[(<]"#,
        #"^(class|struct|enum|interface|protocol|impl|trait|extension) [A-Z]\w*"#,
        #"^(import|using) [A-Za-z_][\w.]*;?$"#,
        #"^(import|export) .* from ['"]"#,
        #"^from [\w.]+ import "#,
        #"^#(include|import|define|pragma|!/)"#,
        #"^(if|while|for|switch|catch)\s*\(.*\)\s*\{?$"#,
        #"^for \w+ in .+:$"#,
        #"^(return|throw|yield)\b.*;$"#,
        #"^(public|private|protected|internal|static|override|async|final) (func|class|static|var|let|void|def|fun|val|int|String|bool|struct|enum)\b"#,
        #"^package [\w.]+;?$"#,
        #"^(console|System\.out|fmt|std|Log|logger)\.[\w.]+\("#,
        #"^print(ln|f)?\(.*\)$"#,
        #"^<\?php"#,
        #"^(SELECT|INSERT INTO|UPDATE|DELETE FROM|CREATE TABLE|ALTER TABLE|WITH) "#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let bulletPattern = try! NSRegularExpression(pattern: #"^(\d+[.)]|[-*•]) "#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// True for source code, a shell command, JSON or SQL.
    static func isCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        if isJSON(trimmed) || isMarkup(trimmed) || isDiff(trimmed) || isDockerfile(trimmed) || isGraphQL(trimmed) { return true }

        let lines = trimmed.prefix(8_000)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(300)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return false }

        if lines.count == 1 {
            let line = first.trimmingCharacters(in: .whitespaces)
            return isCommandLine(line) || isSQL(line) || keywordPatterns.contains { matches($0, line) } && line.contains(where: { "=({;".contains($0) })
        }

        var codeLines = 0
        var keywordLines = 0
        for line in lines {
            let content = line.trimmingCharacters(in: .whitespaces)
            let keyword = keywordPatterns.contains { matches($0, content) } || isCommandLine(content)
            let structure = [";", "{", "}", "};", "*/", "=>"].contains { content.hasSuffix($0) }
                || ["}", "//", "/*", "*/"].contains { content.hasPrefix($0) }
            let indented = !matches(bulletPattern, content) && (line.hasPrefix("    ") || line.hasPrefix("\t"))
            if keyword { keywordLines += 1 }
            if keyword || structure || indented { codeLines += 1 }
        }
        let symbols = trimmed.prefix(8_000).filter { "{}[];=<>".contains($0) }.count
        let ratio = Double(codeLines) / Double(lines.count)
        return ratio >= 0.6 && (keywordLines >= 1 || symbols >= 4) || isSQL(lines.joined(separator: " "))
    }

    private static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[", text.count <= 5_000_000,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let dictionary = object as? [String: Any] { return !dictionary.isEmpty }
        if let array = object as? [Any] { return array.first is [String: Any] || array.first is [Any] || array.count >= 2 }
        return false
    }

    static func isDiff(_ text: String) -> Bool {
        text.hasPrefix("diff --git ") || (text.hasPrefix("--- ") || text.hasPrefix("Index: ")) && text.contains("\n+++ ") && text.contains("\n@@ ")
    }

    private static let dockerInstructions = ["FROM ", "RUN ", "COPY ", "ADD ", "CMD ", "ENV ", "WORKDIR ", "EXPOSE ",
                                             "ENTRYPOINT ", "ARG ", "USER ", "LABEL ", "VOLUME ", "HEALTHCHECK "]

    static func isDockerfile(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count >= 2, let first = lines.first, first.hasPrefix("FROM ") || first.hasPrefix("ARG ") else { return false }
        let instructions = lines.filter { line in dockerInstructions.contains { line.hasPrefix($0) } }.count
        return Double(instructions) / Double(lines.count) >= 0.6
    }

    static func isGraphQL(_ text: String) -> Bool {
        let pattern = try! NSRegularExpression(pattern: #"^(query|mutation|subscription|fragment)\b[^{]*\{[\s\S]*\}$"#)
        return matches(pattern, text)
    }

    /// XML, HTML or SVG: well-formed XML, or mostly tag lines (HTML is often not well-formed).
    static func isMarkup(_ text: String) -> Bool {
        guard text.hasPrefix("<"), text.hasSuffix(">"), text.count <= 2_000_000 else { return false }
        let tagged = text.contains("</") || text.contains("/>") || text.hasPrefix("<?xml") || text.lowercased().hasPrefix("<!doctype")
        guard tagged else { return false }
        if text.count <= 1_000_000, let data = text.data(using: .utf8), XMLParser(data: data).parse() { return true }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tagLines = lines.filter { $0.hasPrefix("<") && $0.hasSuffix(">") }.count
        return Double(tagLines) / Double(max(lines.count, 1)) >= 0.6
    }

    /// "git status", "$ npm install", "ls -la", "cd ~/Projects".
    private static func isCommandLine(_ line: String) -> Bool {
        var content = line.trimmingCharacters(in: .whitespaces)
        var prompted = false
        if content.hasPrefix("$ ") || content.hasPrefix("% ") {
            content = String(content.dropFirst(2))
            prompted = true
        }
        let words = content.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = words.first else { return false }
        let rest = words.count > 1 ? words[1] : ""
        if command == "git" {
            return gitSubcommands.contains(String(rest.split(separator: " ").first ?? ""))
        }
        if strongCommands.contains(command) {
            return !rest.isEmpty && (prompted || rest.first.map { $0.isLowercase || "-./~".contains($0) } == true)
        }
        if ambiguousCommands.contains(command) {
            return prompted || rest.contains(where: { "-/~.|&>=$".contains($0) })
        }
        return false
    }

    /// SQL in capitals, or in lower case with SQL-only syntax ("*", ";", "where").
    private static func isSQL(_ text: String) -> Bool {
        let upper = text.hasPrefix("SELECT ") && text.contains(" FROM ")
            || text.hasPrefix("INSERT INTO ") || text.hasPrefix("DELETE FROM ")
            || text.hasPrefix("UPDATE ") && text.contains(" SET ")
            || text.hasPrefix("CREATE TABLE ") || text.hasPrefix("ALTER TABLE ")
        if upper { return true }
        let lower = text.lowercased()
        let syntax = lower.contains("*") || lower.contains(";") || lower.contains(" where ")
        return syntax && (lower.hasPrefix("select ") && lower.contains(" from ")
            || lower.hasPrefix("delete from ") || lower.hasPrefix("update ") && lower.contains(" set "))
    }

    /// A best guess for the details; never used for grouping.
    static func language(of code: String) -> String {
        let sample = String(code.prefix(4_000))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if isJSON(code.trimmingCharacters(in: .whitespacesAndNewlines)) { return "JSON" }
        if isDiff(trimmed) { return "Diff" }
        if isDockerfile(trimmed) { return "Dockerfile" }
        if isGraphQL(trimmed) { return "GraphQL" }
        if isSQL(lower) || lower.hasPrefix("select ") || lower.hasPrefix("with ") { return "SQL" }
        if lower.hasPrefix("<svg") || lower.hasPrefix("<?xml") && lower.contains("<svg") { return "SVG" }
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.hasPrefix("<div") || lower.hasPrefix("<body") { return "HTML" }
        if isMarkup(trimmed) { return lower.contains("<html") || lower.contains("<div") || lower.contains("<p>") ? "HTML" : "XML" }
        if lower.hasPrefix("<?php") { return "PHP" }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        if trimmed.hasPrefix("#!") || isCommandLine(firstLine) { return "Shell" }
        let rules: [(String, [String])] = [
            ("Swift", ["func ", "guard ", "let ", "import SwiftUI", "import Foundation", "@MainActor", "struct ", "-> "]),
            ("TypeScript", ["interface ", ": string", ": number", "export type ", "import type "]),
            ("JavaScript", ["function ", "const ", "=> ", "console.log", "require(", "export default"]),
            ("Python", ["def ", "elif ", "import ", "self.", "print(", "__init__"]),
            ("Go", ["package ", "func ", ":= ", "fmt."]),
            ("Rust", ["fn ", "let mut ", "impl ", "use std", "println!"]),
            ("Java", ["public class ", "public static void", "System.out"]),
            ("C / C++", ["#include", "int main", "std::", "printf("]),
            ("Ruby", ["def ", "end\n", "puts ", "require '"]),
            ("CSS", ["{\n", "color:", "margin:", "@media"]),
            ("YAML", [": \n", "- name:", "apiVersion:"]),
        ]
        var best = ("Code", 0)
        for (name, markers) in rules {
            let hits = markers.filter { sample.contains($0) }.count
            if hits > best.1 { best = (name, hits) }
        }
        return best.1 >= 2 ? best.0 : "Code"
    }
}
