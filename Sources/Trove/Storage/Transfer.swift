import AppKit
import CryptoKit
import Foundation
import GRDB

/// Import and export of clipboard history.
///
/// Export formats:
/// - `.clipboardexport`: the JSON below, compressed and encrypted with a password
///   (PBKDF2-SHA256 → AES-256-GCM). The default, because history holds private data.
/// - `.json`: the same JSON without encryption, for other tools.
/// - `.csv`: text-like items only.
/// Hidden items are never exported: they are sealed to this Mac's Secure Enclave.
///
/// Import sources: our two formats, Maccy (`Storage.sqlite`) and Alfred (`clipboard.alfdb`).
enum Transfer {
    // MARK: - Schema

    struct Item: Codable, Equatable, Sendable {
        var kind: String
        var text: String?
        /// Base64 in JSON.
        var rtf: Data?
        /// PNG, base64 in JSON.
        var image: Data?
        var imageWidth: Int?
        var imageHeight: Int?
        var files: [String]?
        var format: String?
        var sourceApp: String?
        var sourceBundleID: String?
        var sourceURL: String?
        var pinned: Bool
        /// Snippets only: the name. Older exports have no such field.
        var snippetName: String? = nil
        var timesCopied: Int
        var firstCopiedAt: Date
        var lastCopiedAt: Date
    }

    struct Document: Codable, Sendable {
        var format = "com.iokoda.clipboard.export"
        var version = 1
        var exportedAt: Date
        var items: [Item]
    }

    struct Envelope: Codable, Sendable {
        var format = "com.iokoda.clipboard.export.encrypted"
        var version = 1
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: Data
        /// AES-256-GCM sealed box of the zlib-compressed Document JSON.
        var sealed: Data
    }

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case encrypted, json, csv
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .encrypted: "clipboardexport"
            case .json: "json"
            case .csv: "csv"
            }
        }
    }

    enum TransferError: LocalizedError, Equatable {
        case unknownFile
        case wrongPassword
        case needsPassword
        case newerVersion
        case noClipboardHistory

        var errorDescription: String? {
            switch self {
            case .unknownFile: L("This file is not a Trove export, a Maccy database or an Alfred clipboard database.")
            case .wrongPassword: L("The password is not correct.")
            case .needsPassword: L("This export is encrypted. Enter its password.")
            case .newerVersion: L("This export was made by a newer version of Trove.")
            case .noClipboardHistory: L("This Raycast export has no clipboard history. Export again in Raycast and include Clipboard History.")
            }
        }
    }

    // MARK: - Export

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func json(_ items: [Item], at date: Date = Date()) throws -> Data {
        try encoder().encode(Document(exportedAt: date, items: items))
    }

    static func encrypted(_ items: [Item], password: String, iterations: Int = Vault.defaultIterations) throws -> Data {
        guard password.count >= Vault.minimumPasswordLength else { throw VaultError.passwordTooShort }
        let plain = try JSONEncoder.compact.encode(Document(exportedAt: Date(), items: items))
        let compressed = try (plain as NSData).compressed(using: .zlib) as Data
        let salt = Vault.randomBytes(16)
        let key = try Vault.deriveKey(password: password, salt: salt, iterations: iterations)
        guard let sealed = try AES.GCM.seal(compressed, using: key, authenticating: Data("com.iokoda.clipboard.export".utf8)).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return try encoder().encode(Envelope(iterations: iterations, salt: salt, sealed: sealed))
    }

    /// Text-like items as CSV (RFC 4180 quoting): kind, text, source, first and last copied, times, pinned.
    static func csv(_ items: [Item]) -> Data {
        func field(_ value: String) -> String {
            // A cell starting with = + - @ (or a tab, CR) would run as a formula in Excel or Numbers.
            let value = value.first.map { "=+-@\t\r".contains($0) } == true ? "'" + value : value
            return value.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        let iso = ISO8601DateFormatter()
        var lines = ["kind,text,source,first_copied,last_copied,times_copied,pinned"]
        for item in items where item.text != nil && item.kind != ClipKind.image.rawValue {
            lines.append([item.kind, item.text ?? "", item.sourceApp ?? "", iso.string(from: item.firstCopiedAt),
                          iso.string(from: item.lastCopiedAt), String(item.timesCopied), item.pinned ? "true" : "false"]
                .map(field).joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: - Import

    enum Source: String, Sendable {
        case clipboardEncrypted, clipboardJSON, maccy, alfred, raycast

        /// Formats that open with a password.
        var needsPassword: Bool { self == .clipboardEncrypted || self == .raycast }

        var title: String {
            switch self {
            case .clipboardEncrypted, .clipboardJSON: L("a Trove export")
            case .maccy: "Maccy"
            case .alfred: "Alfred"
            case .raycast: "Raycast"
            }
        }
    }

    /// What a file is, from its content (not its name).
    static func detect(_ url: URL) throws -> Source {
        // Raycast's export is encrypted from the first byte: only its name tells what it is.
        if url.pathExtension.lowercased() == "rayconfig" { return .raycast }
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 4_096) ?? Data()
        try handle.close()
        if head.starts(with: Store.sqliteHeader) {
            // Only the table names: read in place (cheap), the copy is made when reading.
            let queue = try DatabaseQueue(path: url.path, configuration: readOnly)
            defer { try? queue.close() }
            let tables = try queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
            if tables.contains("ZHISTORYITEM") && tables.contains("ZHISTORYITEMCONTENT") { return .maccy }
            if tables.contains("clipboard") { return .alfred }
            throw TransferError.unknownFile
        }
        let text = String(decoding: head, as: UTF8.self)
        if text.contains("com.iokoda.clipboard.export.encrypted") { return .clipboardEncrypted }
        if text.contains("com.iokoda.clipboard.export") { return .clipboardJSON }
        throw TransferError.unknownFile
    }

    static func read(_ url: URL, password: String?) throws -> [Item] {
        try load(url, password: password).items
    }

    /// The items, and how many images the file mentions but does not contain (Raycast).
    static func load(_ url: URL, password: String?) throws -> (items: [Item], skippedImages: Int) {
        if try detect(url) == .raycast {
            guard let password, !password.isEmpty else { throw TransferError.needsPassword }
            do {
                return try RaycastImport.items(fromJSON: RaycastImport.decrypt(Data(contentsOf: url), password: password))
            } catch RaycastImport.Failure.wrongPassword {
                throw TransferError.wrongPassword
            } catch RaycastImport.Failure.noClipboardHistory {
                throw TransferError.noClipboardHistory
            }
        }
        return (try readOther(url, password: password), 0)
    }

    private static func readOther(_ url: URL, password: String?) throws -> [Item] {
        switch try detect(url) {
        case .clipboardJSON:
            let document = try decoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version <= 1 else { throw TransferError.newerVersion }
            return document.items
        case .clipboardEncrypted:
            guard let password, !password.isEmpty else { throw TransferError.needsPassword }
            let envelope = try decoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version <= 1 else { throw TransferError.newerVersion }
            let key = try Vault.deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
            let compressed: Data
            do {
                compressed = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key,
                                              authenticating: Data("com.iokoda.clipboard.export".utf8))
            } catch {
                throw TransferError.wrongPassword
            }
            let plain = try (compressed as NSData).decompressed(using: .zlib) as Data
            let document = try decoder().decode(Document.self, from: plain)
            guard document.version <= 1 else { throw TransferError.newerVersion }
            return document.items
        case .maccy:
            return try readMaccy(url)
        case .alfred:
            return try readAlfred(url)
        case .raycast:
            return [] // Read by `load`.
        }
    }

    /// Another app's database, read from a private copy: the app may be writing to it, and its
    /// newest rows can still be in the write-ahead log next to it (`-wal`, `-shm`), which is
    /// copied too when it can be read (the folder was chosen, not only the file).
    private static func openCopy(_ url: URL) throws -> DatabaseQueue {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try fm.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.isReadableFile(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        let queue = try DatabaseQueue(path: copy.path) // Not read-only: SQLite applies the log to the copy.
        copies.append(folder)
        return queue
    }

    /// The private copies of this run, removed by `removeCopies()` (and with the temporary folder).
    nonisolated(unsafe) private static var copies: [URL] = []

    static func removeCopies() {
        for folder in copies { try? FileManager.default.removeItem(at: folder) }
        copies = []
    }

    private static var readOnly: Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        return configuration
    }

    // MARK: Maccy

    /// Maccy keeps history in a Core Data store: one ZHISTORYITEM row per item and one
    /// ZHISTORYITEMCONTENT row per pasteboard type. Columns are checked first, because the
    /// schema differs between Maccy versions. Core Data dates count seconds from 2001.
    private static func readMaccy(_ url: URL) throws -> [Item] {
        let queue = try openCopy(url)
        defer { try? queue.close() }
        return try queue.read { db in
            let itemColumns = Set(try db.columns(in: "ZHISTORYITEM").map(\.name))
            let contentColumns = Set(try db.columns(in: "ZHISTORYITEMCONTENT").map(\.name))
            guard contentColumns.isSuperset(of: ["ZITEM", "ZTYPE", "ZVALUE"]) else { throw TransferError.unknownFile }
            func column(_ name: String) -> String { itemColumns.contains(name) ? name : "NULL" }

            var contents: [Int64: [String: Data]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT ZITEM, ZTYPE, ZVALUE FROM ZHISTORYITEMCONTENT") {
                guard let item: Int64 = row["ZITEM"], let type: String = row["ZTYPE"], let value: Data = row["ZVALUE"] else { continue }
                contents[item, default: [:]][type] = value
            }
            let sql = """
                SELECT Z_PK, \(column("ZAPPLICATION")) AS app, \(column("ZFIRSTCOPIEDAT")) AS first,
                       \(column("ZLASTCOPIEDAT")) AS last, \(column("ZNUMBEROFCOPIES")) AS times, \(column("ZPIN")) AS pin
                FROM ZHISTORYITEM
                """
            var items: [Item] = []
            for row in try Row.fetchAll(db, sql: sql) {
                guard let id: Int64 = row["Z_PK"], let types = contents[id] else { continue }
                let first = (row["first"] as Double?).map(Date.init(timeIntervalSinceReferenceDate:)) ?? Date()
                let last = (row["last"] as Double?).map(Date.init(timeIntervalSinceReferenceDate:)) ?? first
                let pinned = (row["pin"] as String?).map { !$0.isEmpty } ?? false
                var item = Item(kind: ClipKind.text.rawValue, pinned: pinned, timesCopied: max(1, row["times"] as Int? ?? 1),
                                firstCopiedAt: first, lastCopiedAt: last)
                item.sourceBundleID = row["app"]
                // Maccy keeps the bundle identifier; the app's name is shown when it is installed.
                item.sourceApp = item.sourceBundleID.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
                    .map { $0.deletingPathExtension().lastPathComponent }
                if let fileURL = types["public.file-url"], let string = String(data: fileURL, encoding: .utf8), let url = URL(string: string) {
                    item.kind = ClipKind.file.rawValue
                    item.files = [url.path]
                } else if let text = (types["public.utf8-plain-text"] ?? types["NSStringPboardType"]).flatMap({ String(data: $0, encoding: .utf8) }) {
                    item.text = text
                    item.rtf = types["public.rtf"]
                } else if let image = types["public.png"] ?? types["public.tiff"] {
                    item.kind = ClipKind.image.rawValue
                    item.image = image
                } else {
                    continue
                }
                items.append(item)
            }
            return items
        }
    }

    // MARK: Alfred

    /// Alfred's clipboard database: one `clipboard` row per item. `ts` counts seconds from
    /// 2001; `dataType` is 0 for text and 2 for files (images live in a separate folder and are
    /// not imported).
    private static func readAlfred(_ url: URL) throws -> [Item] {
        let queue = try openCopy(url)
        defer { try? queue.close() }
        return try queue.read { db in
            let columns = Set(try db.columns(in: "clipboard").map(\.name))
            guard columns.contains("item") else { throw TransferError.unknownFile }
            func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
            let sql = "SELECT item, \(column("ts")) AS ts, \(column("app")) AS app, \(column("dataType")) AS type FROM clipboard"
            var items: [Item] = []
            for row in try Row.fetchAll(db, sql: sql) {
                guard let text: String = row["item"], !text.isEmpty else { continue }
                let date = (row["ts"] as Double?).map(Date.init(timeIntervalSinceReferenceDate:)) ?? Date()
                let type = row["type"] as Int? ?? 0
                var item = Item(kind: ClipKind.text.rawValue, pinned: false, timesCopied: 1, firstCopiedAt: date, lastCopiedAt: date)
                item.sourceApp = row["app"]
                switch type {
                case 0: item.text = text
                case 2:
                    item.kind = ClipKind.file.rawValue
                    item.files = text.split(separator: "\n").map(String.init)
                default: continue
                }
                items.append(item)
            }
            return items
        }
    }
}

extension JSONEncoder {
    static var compact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
