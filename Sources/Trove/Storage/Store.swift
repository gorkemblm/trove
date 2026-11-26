import CryptoKit
import Foundation
import GRDB

enum StoreError: LocalizedError {
    case encryptionCheckFailed

    var errorDescription: String? {
        switch self {
        case .encryptionCheckFailed: L("The encrypted copy of the history did not match the original. Nothing was changed.")
        }
    }
}

/// An app things were copied in. Items without a bundle identifier match by name.
struct SourceApp: Identifiable, Equatable, Sendable {
    let bundleID: String?
    let name: String
    var count: Int = 0
    var id: String { bundleID ?? name }

    /// "ar" finds Arc; "code" finds Visual Studio Code.
    func matches(_ typed: String) -> Bool {
        let typed = typed.searchFolded
        guard !typed.isEmpty else { return true }
        let folded = name.searchFolded
        return folded.hasPrefix(typed) || folded.split(separator: " ").contains { $0.hasPrefix(typed) }
    }
}

struct StoreUsage: Equatable, Sendable {
    var count = 0
    var totalBytes = 0
    var imageBytes = 0
}

/// What happens to the unencrypted files of a version 0.1 history after encryption.
/// They are never deleted: they go to a backup folder, then (by default) to the Trash.
enum PlaintextOriginals: Sendable {
    case moveToTrash
    case keepInFolder
}

struct PruneLimits: Equatable, Sendable {
    /// 0 means forever.
    var retentionDays: Int
    /// 0 means unlimited.
    var maxItems: Int
    /// 0 means unlimited.
    var maxBytes: Int
}

/// The clipboard history: one SQLCipher database plus an Images folder, in one directory.
///
/// Everything on disk is encrypted with keys derived from the folder's `DataKey`: the database
/// (including the search index) with SQLCipher, each image with AES-256-GCM.
@MainActor
final class Store {
    nonisolated static let databaseFileName = "clipboard.sqlite"
    nonisolated static let imagesFolderName = "Images"
    /// Everything that belongs to a store directory. Used when the user moves the store.
    nonisolated static let fileNames = [
        databaseFileName, databaseFileName + "-wal", databaseFileName + "-shm", databaseFileName + "-journal",
        imagesFolderName, KeyFile.fileName,
    ]
    /// Temporary name while an unencrypted database is converted.
    nonisolated static let encryptingFileName = databaseFileName + ".encrypting"

    let directory: URL
    let imagesDirectory: URL
    /// Set when this open encrypted an old history and its unencrypted originals stayed in the
    /// folder (by request, or because the Trash was not available).
    private(set) var unencryptedBackup: URL?
    private let dbQueue: DatabaseQueue
    private let imageKey: SymmetricKey

    private init(directory: URL, imagesDirectory: URL, dbQueue: DatabaseQueue, key: DataKey) {
        self.directory = directory
        self.imagesDirectory = imagesDirectory
        self.dbQueue = dbQueue
        self.imageKey = key.imageKey
    }

    static func open(directory: URL, key: DataKey, originals: PlaintextOriginals = .moveToTrash) throws -> Store {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let images = directory.appendingPathComponent(imagesFolderName, isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)

        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let backup = directory.appendingPathComponent("Unencrypted backup \(stamp)", isDirectory: true)

        let databaseURL = directory.appendingPathComponent(databaseFileName)
        try encryptPlaintextDatabaseIfNeeded(at: databaseURL, key: key, backupFolder: backup)
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration(key: key))
        try migrator.migrate(queue)
        let store = Store(directory: directory, imagesDirectory: images, dbQueue: queue, key: key)
        try store.encryptPlaintextImages(backupFolder: backup)

        if fm.fileExists(atPath: backup.path) {
            if originals == .moveToTrash {
                try? fm.trashItem(at: backup, resultingItemURL: nil)
            }
            if fm.fileExists(atPath: backup.path) { store.unencryptedBackup = backup }
        }
        return store
    }

    /// In-memory store for tests and snapshots. Image files are still encrypted.
    static func inMemory(imagesDirectory: URL, key: DataKey = .random()) throws -> Store {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        return Store(directory: imagesDirectory.deletingLastPathComponent(), imagesDirectory: imagesDirectory, dbQueue: queue, key: key)
    }

    func close() throws {
        try dbQueue.close()
    }

    private nonisolated static func configuration(key: DataKey) -> Configuration {
        var config = Configuration()
        let passphrase = key.databasePassphrase
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
            // SQLCipher decrypts each page it reads from disk. A 32 MB page cache keeps the pages
            // that lists and searches use in memory, already decrypted.
            try db.execute(sql: "PRAGMA cache_size = -32768")
        }
        return config
    }

    // MARK: - Encryption of older, unencrypted folders

    nonisolated static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    /// True when the folder holds data that only a key can read: an encrypted database or
    /// encrypted image files. An unencrypted database from version 0.1 does not count.
    nonisolated static func hasEncryptedData(in directory: URL) -> Bool {
        let fm = FileManager.default
        // A leftover ".encrypting" copy does not count: the original database is still intact.
        if let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(databaseFileName)) {
            let header = (try? handle.read(upToCount: sqliteHeader.count)) ?? Data()
            try? handle.close()
            if !header.isEmpty, header != sqliteHeader { return true }
        }
        let images = directory.appendingPathComponent(imagesFolderName)
        let files = (try? fm.contentsOfDirectory(atPath: images.path)) ?? []
        return files.contains { $0.hasSuffix("." + EncryptedFile.fileExtension) }
    }

    nonisolated static func isPlaintextDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: sqliteHeader.count)) == sqliteHeader
    }

    /// Converts an unencrypted database to SQLCipher with `sqlcipher_export` and checks the copy.
    /// Then the original moves to `backupFolder` and the copy takes its place. The original is
    /// never deleted here. After a crash between the two moves, the next open finishes the swap.
    nonisolated static func encryptPlaintextDatabaseIfNeeded(at url: URL, key: DataKey, backupFolder: URL) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(encryptingFileName)
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: temp.path) {
            try fm.moveItem(at: temp, to: url) // The checked copy of an interrupted swap.
            return
        }
        guard isPlaintextDatabase(url) else {
            try? fm.removeItem(at: temp) // An unfinished copy; the original is intact.
            return
        }
        try? fm.removeItem(at: temp)

        let plain = try DatabaseQueue(path: url.path)
        let expected: [String: Int] = try plain.read { db in try rowCounts(db) }
        try plain.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS encrypted KEY ?", arguments: [temp.path, key.databasePassphrase])
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
            try db.execute(sql: "DETACH DATABASE encrypted")
        }
        try plain.close()

        let check = try DatabaseQueue(path: temp.path, configuration: configuration(key: key))
        let actual: [String: Int] = try check.read { db in try rowCounts(db) }
        let integrity = try check.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        try check.close()
        guard actual == expected, integrity == "ok" else {
            try? fm.removeItem(at: temp)
            throw StoreError.encryptionCheckFailed
        }

        try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            try fm.moveItem(at: file, to: backupFolder.appendingPathComponent(file.lastPathComponent))
        }
        try fm.moveItem(at: temp, to: url)
    }

    private nonisolated static func rowCounts(_ db: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'clip_fts%'")
        for table in tables {
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
        }
        return counts
    }

    /// Images saved by version 0.1 are plain PNG files named after their content hash.
    /// Each one is encrypted to a new random name, then the original moves to the backup folder.
    private func encryptPlaintextImages(backupFolder: URL) throws {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, imageFile FROM clip WHERE imageFile IS NOT NULL AND imageFile NOT LIKE ?",
                             arguments: ["%." + EncryptedFile.fileExtension])
        }
        for row in rows {
            let id: Int64 = row["id"]
            let oldName: String = row["imageFile"]
            let oldURL = imagesDirectory.appendingPathComponent(oldName)
            guard let data = try? Data(contentsOf: oldURL) else {
                try dbQueue.write { db in try db.execute(sql: "UPDATE clip SET imageFile = NULL WHERE id = ?", arguments: [id]) }
                continue
            }
            let newName = try writeImage(data)
            try dbQueue.write { db in try db.execute(sql: "UPDATE clip SET imageFile = ? WHERE id = ?", arguments: [newName, id]) }
            let backupImages = backupFolder.appendingPathComponent(Self.imagesFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: backupImages, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: oldURL, to: backupImages.appendingPathComponent(oldName))
        }
    }

    // MARK: - Images

    /// Encrypts and writes image data. Returns the new file name.
    private func writeImage(_ data: Data) throws -> String {
        let name = UUID().uuidString.lowercased() + "." + EncryptedFile.fileExtension
        let sealed = try EncryptedFile.seal(data, with: imageKey)
        try sealed.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// The decrypted image of a clip, or nil when the file is missing or damaged.
    func imageData(for clip: Clip) -> Data? {
        guard let name = clip.imageFile,
              let file = try? Data(contentsOf: imagesDirectory.appendingPathComponent(name)) else { return nil }
        return try? EncryptedFile.open(file, with: imageKey)
    }

    /// Moves the history to another folder, all or nothing: when a file cannot be moved (a full
    /// disk), the files already moved go back, so the history stays whole in the old folder.
    /// Nothing that is already in the destination is overwritten.
    static func moveFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let present = fileNames.filter { fm.fileExists(atPath: source.appendingPathComponent($0).path) }
        if let clash = present.first(where: { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.appendingPathComponent(clash).path])
        }
        var moved: [String] = []
        do {
            for name in present {
                try fm.moveItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
                moved.append(name)
            }
        } catch {
            for name in moved.reversed() {
                try? fm.moveItem(at: destination.appendingPathComponent(name), to: source.appendingPathComponent(name))
            }
            throw error
        }
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v0-meta") { db in
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v1-clips") { db in
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull().indexed()
                t.column("text", .text)
                t.column("rtf", .blob)
                t.column("imageFile", .text)
                t.column("imageWidth", .integer)
                t.column("imageHeight", .integer)
                t.column("fileSize", .integer)
                t.column("byteSize", .integer).notNull()
                t.column("contentHash", .text).notNull().unique()
                t.column("sourceBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("sourceURL", .text)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("timesCopied", .integer).notNull().defaults(to: 1)
                t.column("firstCopiedAt", .datetime).notNull()
                t.column("lastCopiedAt", .datetime).notNull().indexed()
            }
            // Trigram index: case-insensitive substring search ("hub" finds "github").
            try db.create(virtualTable: "clip_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clip")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("text")
                t.column("sourceAppName")
            }
        }
        // v2 rebuilds the table for large histories:
        // - Small columns come first and large ones (searchText, text, rtf) last. SQLite walks a
        //   large value's overflow pages to reach any column stored after it, so a 200 KB text in
        //   the middle of a row made every list query slow.
        // - Lists and search read `searchText` (first 20,000 characters). The full text is read
        //   only for the selected item and for copying.
        migrator.registerMigration("v2-row-layout") { db in
            try db.dropFTS5SynchronizationTriggers(forTable: "clip_fts")
            try db.drop(table: "clip_fts")
            try db.execute(sql: """
                CREATE TABLE clip_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    pinned BOOLEAN NOT NULL DEFAULT 0,
                    lastCopiedAt DATETIME NOT NULL,
                    firstCopiedAt DATETIME NOT NULL,
                    timesCopied INTEGER NOT NULL DEFAULT 1,
                    byteSize INTEGER NOT NULL,
                    contentHash TEXT NOT NULL UNIQUE,
                    imageFile TEXT,
                    imageWidth INTEGER,
                    imageHeight INTEGER,
                    fileSize INTEGER,
                    sourceBundleID TEXT,
                    sourceAppName TEXT,
                    sourceURL TEXT,
                    textCharacters INTEGER,
                    textWords INTEGER,
                    textLines INTEGER,
                    searchText TEXT,
                    text TEXT,
                    rtf BLOB
                );
                INSERT INTO clip_new (id, kind, pinned, lastCopiedAt, firstCopiedAt, timesCopied, byteSize, contentHash,
                                      imageFile, imageWidth, imageHeight, fileSize, sourceBundleID, sourceAppName,
                                      sourceURL, text, rtf)
                SELECT id, kind, pinned, lastCopiedAt, firstCopiedAt, timesCopied, byteSize, contentHash,
                       imageFile, imageWidth, imageHeight, fileSize, sourceBundleID, sourceAppName,
                       sourceURL, text, rtf
                FROM clip;
                DROP TABLE clip;
                ALTER TABLE clip_new RENAME TO clip;
                CREATE INDEX clip_lastCopiedAt ON clip(lastCopiedAt);
                CREATE INDEX clip_kind_lastCopiedAt ON clip(kind, lastCopiedAt);
                CREATE INDEX clip_pinned_lastCopiedAt ON clip(pinned, lastCopiedAt);
                """)
            for row in try Row.fetchAll(db, sql: "SELECT id, kind, text FROM clip") {
                var clip = Clip(
                    id: row["id"], kind: ClipKind(rawValue: row["kind"]) ?? .text, text: row["text"], rtf: nil,
                    byteSize: 0, contentHash: "", pinned: false, timesCopied: 0,
                    firstCopiedAt: Date(), lastCopiedAt: Date()
                )
                clip.prepareDerivedFields()
                try db.execute(
                    sql: "UPDATE clip SET searchText = ?, textCharacters = ?, textWords = ?, textLines = ? WHERE id = ?",
                    arguments: [clip.searchText, clip.textCharacters, clip.textWords, clip.textLines, clip.id]
                )
            }
            try db.create(virtualTable: "clip_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clip")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("searchText")
                t.column("sourceAppName")
            }
            try db.execute(sql: "INSERT INTO clip_fts(clip_fts) VALUES('rebuild')")
        }
        // v3 adds hidden items. The new columns come after the large ones, so list queries read
        // them only for hidden rows (see `listColumns`), and expiry uses a partial index.
        migrator.registerMigration("v3-hidden") { db in
            try db.execute(sql: """
                ALTER TABLE clip ADD COLUMN secretReason TEXT;
                ALTER TABLE clip ADD COLUMN sealed BLOB;
                ALTER TABLE clip ADD COLUMN expiresAt DATETIME;
                CREATE INDEX clip_expiresAt ON clip(expiresAt) WHERE expiresAt IS NOT NULL;
                """)
        }
        // v4 sorts existing text into code, e-mail and phone. The hash follows the new kind, so a
        // later copy of the same text merges with it. When that hash already exists (the same
        // address saved twice with different spacing), the row stays text.
        migrator.registerMigration("v4-content-types") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM clip WHERE kind = 'text'")
            for row in rows {
                guard let text: String = row["text"] else { continue }
                let content = ClipClassifier.textContent(text, rtf: nil)
                guard content.kind != .text, let value = content.text else { continue }
                var clip = Clip(id: row["id"], kind: content.kind, text: value, rtf: nil, byteSize: 0, contentHash: "",
                                pinned: false, timesCopied: 0, firstCopiedAt: Date(), lastCopiedAt: Date())
                clip.prepareDerivedFields()
                try db.execute(
                    sql: "UPDATE OR IGNORE clip SET kind = ?, text = ?, contentHash = ?, searchText = ? WHERE id = ?",
                    arguments: [content.kind.rawValue, value, content.hash, clip.searchText, row["id"] as Int64]
                )
            }
        }
        // v5 adds structured data. `format` holds the language of code and the format of data;
        // list queries read it only for those rows. Text and code are sorted again, because
        // JSON was code in v4 and data now.
        migrator.registerMigration("v5-data-formats") { db in
            try db.execute(sql: "ALTER TABLE clip ADD COLUMN format TEXT")
            let rows = try Row.fetchAll(db, sql: "SELECT id, kind, text FROM clip WHERE kind IN ('text', 'code')")
            for row in rows {
                guard let text: String = row["text"] else { continue }
                let content = ClipClassifier.textContent(text, rtf: nil)
                let oldKind: String = row["kind"]
                guard content.kind == .code || content.kind == .data || content.kind.rawValue != oldKind,
                      content.kind != .text, let value = content.text else { continue }
                var clip = Clip(id: row["id"], kind: content.kind, text: value, rtf: nil, byteSize: 0, contentHash: "",
                                pinned: false, timesCopied: 0, firstCopiedAt: Date(), lastCopiedAt: Date())
                clip.prepareDerivedFields()
                try db.execute(
                    sql: "UPDATE OR IGNORE clip SET kind = ?, text = ?, contentHash = ?, searchText = ?, format = ? WHERE id = ?",
                    arguments: [content.kind.rawValue, value, content.hash, clip.searchText, content.format, row["id"] as Int64]
                )
            }
        }
        // v6: image files also show in Images. Existing file rows are marked from their names.
        migrator.registerMigration("v6-image-files") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM clip WHERE kind = 'file'")
            for row in rows {
                guard let text: String = row["text"], Clip.areImageFiles(text.split(separator: "\n").map(String.init)) else { continue }
                try db.execute(sql: "UPDATE clip SET format = ? WHERE id = ?", arguments: [Clip.imageFilesFormat, row["id"] as Int64])
            }
        }
        // v7: text found in images. Search covers it, so the search index is built again with
        // a third column. Images are read later, in the background (TextIndexer).
        migrator.registerMigration("v7-recognized-text") { db in
            try db.execute(sql: "ALTER TABLE clip ADD COLUMN recognizedText TEXT")
            try db.dropFTS5SynchronizationTriggers(forTable: "clip_fts")
            try db.drop(table: "clip_fts")
            try db.create(virtualTable: "clip_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clip")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("searchText")
                t.column("sourceAppName")
                t.column("recognizedText")
            }
            try db.execute(sql: "INSERT INTO clip_fts(clip_fts) VALUES('rebuild')")
        }
        // v8: where each line of text is in the image (boxes on the preview, matching lines).
        // Images are read again in the background to get them.
        // The search index reads a folded copy of the text (recognizedSearch), so a search
        // matches whether or not Turkish letters were typed or read.
        migrator.registerMigration("v8-recognized-layout") { db in
            try db.execute(sql: "ALTER TABLE clip ADD COLUMN recognizedLayout TEXT")
            try db.execute(sql: "ALTER TABLE clip ADD COLUMN recognizedSearch TEXT")
            try db.execute(sql: "UPDATE clip SET recognizedText = NULL WHERE recognizedText IS NOT NULL")
            try db.dropFTS5SynchronizationTriggers(forTable: "clip_fts")
            try db.drop(table: "clip_fts")
            try db.create(virtualTable: "clip_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clip")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("searchText")
                t.column("sourceAppName")
                t.column("recognizedSearch")
            }
            try db.execute(sql: "INSERT INTO clip_fts(clip_fts) VALUES('rebuild')")
        }
        // v9: snippets. Kept like pinned items: pruning and Clear skip them.
        migrator.registerMigration("v9-snippets") { db in
            try db.execute(sql: "ALTER TABLE clip ADD COLUMN snippetName TEXT")
            try db.execute(sql: "CREATE INDEX clip_snippet ON clip(snippetName) WHERE snippetName IS NOT NULL")
        }
        return migrator
    }

    /// The list holds this many characters per item: enough for the title line.
    /// The detail view loads the selected item separately.
    nonisolated static let listCharacters = 2_000

    /// Columns for list queries: a short text from `searchText`, no full text and no RTF data.
    private static let listColumns = """
        id, kind, CASE WHEN kind = 'secret' THEN text ELSE substr(searchText, 1, \(listCharacters)) END AS text, NULL AS rtf, imageFile, imageWidth, imageHeight,
        fileSize, byteSize, contentHash, sourceBundleID, sourceAppName, sourceURL, pinned, timesCopied,
        firstCopiedAt, lastCopiedAt, textCharacters, textWords, textLines,
        CASE WHEN kind = 'secret' THEN secretReason END AS secretReason,
        CASE WHEN kind IN ('code', 'data', 'secret', 'file') THEN format END AS format,
        NULL AS recognizedText, NULL AS recognizedLayout, NULL AS recognizedSearch, snippetName
        """

    // MARK: - Writing

    /// Saves new content, or moves existing identical content to the top and counts the copy.
    @discardableResult
    func ingest(_ content: CapturedContent, source: ClipSource, at date: Date) throws -> Clip {
        try dbQueue.write { db in
            // A screenshot file copied in Finder is the screenshot already in history: that item
            // moves to the top, no second copy is made.
            if content.kind == .file, let path = content.text, !path.contains("\n"),
               var shot = try Clip.filter(Column("kind") == ClipKind.image.rawValue && Column("text") == path).fetchOne(db) {
                shot.timesCopied += 1
                shot.lastCopiedAt = date
                try shot.update(db)
                return shot
            }
            if var existing = try Clip.filter(Column("contentHash") == content.hash).fetchOne(db) {
                existing.timesCopied += 1
                existing.lastCopiedAt = date
                if source.bundleID != nil {
                    existing.sourceBundleID = source.bundleID
                    existing.sourceAppName = source.appName
                }
                if let url = source.url { existing.sourceURL = url }
                if existing.kind == .image, let path = content.text {
                    existing.text = path // The newest saved file of this screenshot.
                    existing.prepareDerivedFields()
                }
                // An image file copied before previews existed gets one when copied again.
                if existing.kind == .file {
                    existing.format = content.format
                    if existing.imageFile == nil, let data = content.imageData {
                        existing.imageFile = try writeImage(data)
                        existing.imageWidth = content.imageWidth
                        existing.imageHeight = content.imageHeight
                        existing.byteSize = content.byteSize
                    }
                }
                try existing.update(db)
                return existing
            }

            let imageFile = try content.imageData.map(writeImage)
            var clip = Clip(
                id: nil, kind: content.kind, text: content.text, rtf: content.rtf,
                imageFile: imageFile, imageWidth: content.imageWidth, imageHeight: content.imageHeight,
                fileSize: content.fileSize, byteSize: content.byteSize, contentHash: content.hash,
                sourceBundleID: source.bundleID, sourceAppName: source.appName, sourceURL: source.url,
                pinned: false, timesCopied: 1, firstCopiedAt: date, lastCopiedAt: date, format: content.format
            )
            clip.prepareDerivedFields()
            try clip.insert(db)
            return clip
        }
    }

    /// Inserts a complete clip as given. Used by tests and snapshot mode.
    @discardableResult
    func insert(_ clip: Clip) throws -> Clip {
        try dbQueue.write { db in
            var copy = clip
            copy.prepareDerivedFields()
            try copy.insert(db)
            return copy
        }
    }

    /// Saves a hidden item. Copies of the same secret are not merged: merging would need a
    /// hash of the secret, and a hash of a short secret (a card number) can be reversed.
    @discardableResult
    /// A Hidden item of this kind, masked form and time is already there (an import done twice).
    func hasSecret(finding: SensitiveDetector.Finding, characters: Int, at date: Date) throws -> Bool {
        try dbQueue.read { db in
            try Clip.filter(Column("kind") == ClipKind.secret.rawValue && Column("text") == finding.masked
                            && Column("secretReason") == finding.reason && Column("lastCopiedAt") == date)
                .fetchCount(db) > 0
        }
    }

    func ingestSecret(sealed: Data, finding: SensitiveDetector.Finding, characters: Int, source: ClipSource,
                      at date: Date, expiresAt: Date?) throws -> Clip {
        var clip = Clip(
            id: nil, kind: .secret, text: finding.masked, rtf: nil,
            byteSize: sealed.count, contentHash: "secret-" + UUID().uuidString,
            sourceBundleID: source.bundleID, sourceAppName: source.appName, sourceURL: source.url,
            pinned: false, timesCopied: 1, firstCopiedAt: date, lastCopiedAt: date,
            textCharacters: characters, secretReason: finding.reason, sealed: sealed, expiresAt: expiresAt
        )
        clip.prepareDerivedFields()
        try dbQueue.write { db in try clip.insert(db) }
        return clip
    }

    /// The reason saved for items the user hid on purpose.
    nonisolated static let manualReason = "Hidden manually"
    /// Manually hidden items show no character of their content.
    nonisolated static let fullMask = "••••••••"

    /// Moves an item to Hidden: its content is replaced by the sealed form, so the plain text
    /// leaves the history and the search index. The search finds it by name only.
    func hide(id: Int64, sealed: Data, characters: Int, name: String?) throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE clip SET kind = 'secret', text = ?, rtf = NULL, searchText = ?, secretReason = ?, sealed = ?,
                    format = ?, pinned = 0, contentHash = ?, textCharacters = ?, textWords = NULL, textLines = NULL,
                    sourceURL = NULL, expiresAt = NULL
                WHERE id = ?
                """, arguments: [Self.fullMask, Self.secretSearchText(reason: Self.manualReason, name: name, masked: nil),
                                  Self.manualReason, sealed, name, "secret-" + UUID().uuidString, characters, id])
        }
    }

    /// Names a hidden item ("Work GitHub token"), or removes the name with nil.
    func renameSecret(id: Int64, name: String?) throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT secretReason, text FROM clip WHERE id = ? AND kind = 'secret'", arguments: [id]) else { return }
            let reason: String? = row["secretReason"]
            let masked: String? = row["text"]
            try db.execute(sql: "UPDATE clip SET format = ?, searchText = ? WHERE id = ?",
                           arguments: [name, Self.secretSearchText(reason: reason, name: name, masked: masked), id])
        }
    }

    /// Hidden items are found by type, name and masked form, never by content.
    nonisolated static func secretSearchText(reason: String?, name: String?, masked: String?) -> String {
        [reason, name, masked == fullMask ? nil : masked].compactMap { $0 }.joined(separator: " ")
    }

    /// Moves a hidden item back to the normal history with its dates. If the same content is
    /// already there, the two merge.
    func unhide(id: Int64, content: CapturedContent) throws {
        guard let secret = try clip(id: id), secret.kind == .secret else { return }
        _ = try importRecords([ImportRecord(
            content: content,
            source: ClipSource(bundleID: secret.sourceBundleID, appName: secret.sourceAppName, url: nil),
            firstCopiedAt: secret.firstCopiedAt, lastCopiedAt: secret.lastCopiedAt,
            timesCopied: secret.timesCopied, pinned: false
        )])
        try dbQueue.write { db in _ = try Clip.deleteOne(db, key: id) }
    }

    /// The earliest time a hidden item deletes itself, if any.
    func nextExpiry() throws -> Date? {
        try dbQueue.read { db in try Date.fetchOne(db, sql: "SELECT MIN(expiresAt) FROM clip WHERE expiresAt IS NOT NULL") }
    }

    // MARK: - Import and export

    /// An item read from an import file, ready to save.
    struct ImportRecord: Sendable {
        var content: CapturedContent
        var source: ClipSource
        var firstCopiedAt: Date
        var lastCopiedAt: Date
        var timesCopied: Int
        var pinned: Bool
        var snippetName: String? = nil
    }

    /// How many of these content keys are already in the history (an import merges them).
    func existingCount(ofHashes hashes: [String]) throws -> Int {
        try dbQueue.read { db in
            var count = 0
            for start in stride(from: 0, to: hashes.count, by: 500) {
                let chunk = Array(hashes[start..<min(start + 500, hashes.count)])
                count += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip WHERE contentHash IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")",
                                          arguments: StatementArguments(chunk)) ?? 0
            }
            return count
        }
    }

    func totalCount() throws -> Int {
        try dbQueue.read { db in try Clip.fetchCount(db) }
    }

    /// Saves imported items in one transaction. An item already in the history is merged, not
    /// duplicated: earliest first copy, latest last copy, the higher count, pinned if either is.
    func importRecords(_ records: [ImportRecord]) throws -> (added: Int, merged: Int) {
        try dbQueue.write { db in
            var added = 0
            var merged = 0
            for record in records {
                // A snippet keeps its own content key; the same snippet (name and text) is not added twice.
                if let name = record.snippetName {
                    if try Clip.filter(Column("snippetName") == name && Column("text") == record.content.text).fetchCount(db) > 0 {
                        merged += 1
                        continue
                    }
                } else if var existing = try Clip.filter(Column("contentHash") == record.content.hash).fetchOne(db) {
                    existing.firstCopiedAt = min(existing.firstCopiedAt, record.firstCopiedAt)
                    existing.lastCopiedAt = max(existing.lastCopiedAt, record.lastCopiedAt)
                    existing.timesCopied = max(existing.timesCopied, record.timesCopied)
                    existing.pinned = existing.pinned || record.pinned
                    try existing.update(db)
                    merged += 1
                    continue
                }
                let content = record.content
                let imageFile = try content.imageData.map(writeImage)
                var clip = Clip(
                    id: nil, kind: content.kind, text: content.text, rtf: content.rtf,
                    imageFile: imageFile, imageWidth: content.imageWidth, imageHeight: content.imageHeight,
                    fileSize: content.fileSize, byteSize: content.byteSize, contentHash: content.hash,
                    sourceBundleID: record.source.bundleID, sourceAppName: record.source.appName, sourceURL: record.source.url,
                    pinned: record.pinned, timesCopied: max(1, record.timesCopied),
                    firstCopiedAt: record.firstCopiedAt, lastCopiedAt: record.lastCopiedAt, format: content.format
                )
                if let name = record.snippetName {
                    clip.snippetName = name
                    clip.contentHash = "snippet:" + UUID().uuidString
                }
                clip.prepareDerivedFields()
                try clip.insert(db)
                added += 1
            }
            return (added, merged)
        }
    }

    /// The items an export writes, newest first. Hidden items are never included.
    func exportItems(since: Date?, pinnedOnly: Bool, includeImages: Bool) throws -> [Transfer.Item] {
        let clips = try dbQueue.read { db in
            var request = Clip.filter(Column("kind") != ClipKind.secret.rawValue)
            if let since { request = request.filter(Column("lastCopiedAt") >= since) }
            // "Pinned items and snippets only": what the user chose to keep.
            if pinnedOnly { request = request.filter(Column("pinned") == true || Column("snippetName") != nil) }
            return try request.order(Column("lastCopiedAt").desc).fetchAll(db)
        }
        return clips.compactMap { clip in
            var item = Transfer.Item(
                kind: clip.kind.rawValue, format: clip.format, sourceApp: clip.sourceAppName,
                sourceBundleID: clip.sourceBundleID, sourceURL: clip.sourceURL, pinned: clip.pinned,
                snippetName: clip.snippetName, timesCopied: clip.timesCopied, firstCopiedAt: clip.firstCopiedAt, lastCopiedAt: clip.lastCopiedAt
            )
            switch clip.kind {
            case .image:
                guard includeImages, let data = imageData(for: clip) else { return nil }
                item.image = data
                item.imageWidth = clip.imageWidth
                item.imageHeight = clip.imageHeight
            case .file:
                item.files = clip.filePaths
            default:
                item.text = clip.text
                item.rtf = clip.rtf
            }
            return item
        }
    }

    /// Inserts many complete clips in one transaction. Used by tests (and later by import).
    func insert(_ clips: [Clip]) throws -> [Clip] {
        try dbQueue.write { db in
            try clips.map { clip in
                var copy = clip
                copy.prepareDerivedFields()
                try copy.insert(db)
                return copy
            }
        }
    }

    /// The complete clip, with full text and rich text. List queries return only a preview.
    // MARK: - Apps

    /// The apps things were copied in, most used first (for "@" in the search field).
    func sourceApps(limit: Int = 100) throws -> [SourceApp] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sourceBundleID, sourceAppName, COUNT(*) AS n FROM clip
                WHERE kind != 'secret' AND sourceAppName IS NOT NULL
                GROUP BY COALESCE(sourceBundleID, sourceAppName) ORDER BY n DESC LIMIT ?
                """, arguments: [limit])
                .map { SourceApp(bundleID: $0["sourceBundleID"], name: $0["sourceAppName"], count: $0["n"]) }
        }
    }

    // MARK: - Snippets

    /// Makes a text item a snippet. It gets its own content key, so copying the same text again
    /// adds a history item and leaves the snippet where it is.
    func makeSnippet(id: Int64, name: String) throws {
        try dbQueue.write { db in
            guard var clip = try Clip.fetchOne(db, key: id), clip.kind.isTextual else { return }
            clip.snippetName = name
            clip.contentHash = "snippet:" + UUID().uuidString
            clip.prepareDerivedFields()
            try clip.update(db)
        }
    }

    func renameSnippet(id: Int64, name: String) throws {
        try dbQueue.write { db in
            guard var clip = try Clip.fetchOne(db, key: id), clip.isSnippet else { return }
            clip.snippetName = name
            clip.prepareDerivedFields()
            try clip.update(db)
        }
    }

    /// Back to an ordinary history item (it is pruned like the others from now on).
    func removeSnippet(id: Int64) throws {
        try dbQueue.write { db in
            guard var clip = try Clip.fetchOne(db, key: id), clip.isSnippet else { return }
            clip.snippetName = nil
            clip.contentHash = ClipClassifier.hash(clip.kind.rawValue, (clip.text ?? "") + "\u{0}" + UUID().uuidString)
            clip.prepareDerivedFields()
            try clip.update(db)
        }
    }

    /// A new, empty snippet (⌘K › New Snippet); its text is written in the editor next.
    @discardableResult
    func newSnippet(name: String, at date: Date = Date()) throws -> Clip {
        try dbQueue.write { db in
            var clip = Clip(id: nil, kind: .text, text: "", rtf: nil, byteSize: 0, contentHash: "snippet:" + UUID().uuidString,
                            pinned: false, timesCopied: 0, firstCopiedAt: date, lastCopiedAt: date)
            clip.snippetName = name
            clip.prepareDerivedFields()
            try clip.insert(db)
            return clip
        }
    }

    /// The editor saved a snippet's text. Its kind follows the new text (a link, code…).
    func updateSnippetText(id: Int64, _ text: String) throws {
        try dbQueue.write { db in
            guard var clip = try Clip.fetchOne(db, key: id), clip.isSnippet else { return }
            let content = ClipClassifier.textContent(text, rtf: nil)
            clip.kind = content.kind
            clip.text = content.text
            clip.rtf = nil
            clip.format = content.format
            clip.byteSize = content.byteSize
            clip.textCharacters = nil
            clip.textWords = nil
            clip.textLines = nil
            clip.prepareDerivedFields()
            try clip.update(db)
        }
    }

    // MARK: - Text in images

    /// Images (and image files with a preview) whose text has not been read yet, newest first.
    func imagesAwaitingRecognition(limit: Int) throws -> [Clip] {
        try dbQueue.read { db in
            try Clip.fetchAll(db, sql: """
                SELECT * FROM clip WHERE recognizedText IS NULL AND imageFile IS NOT NULL AND kind IN ('image', 'file')
                ORDER BY lastCopiedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// How many images are read, and how many there are (for Settings).
    func recognitionProgress() throws -> (done: Int, total: Int) {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total, COUNT(recognizedText) AS done FROM clip
                WHERE imageFile IS NOT NULL AND kind IN ('image', 'file')
                """)
            return (row?["done"] ?? 0, row?["total"] ?? 0)
        }
    }

    /// Saves what Vision read. Nil (an image Vision cannot read) or no lines are saved as an
    /// empty text, so the image is not read again.
    func setRecognizedText(id: Int64, _ result: RecognizedText?) throws {
        let lines = result?.lines.isEmpty == false ? result : nil
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clip SET recognizedText = ?, recognizedLayout = ?, recognizedSearch = ? WHERE id = ?",
                           arguments: [lines?.plainText ?? "", lines?.json, lines?.plainText.searchFolded, id])
        }
    }

    /// The read text of some items (for the list's "found in the image" line).
    func recognizedTexts(ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, recognizedText FROM clip WHERE id IN (" + ids.map { _ in "?" }.joined(separator: ",")
                                        + ") AND recognizedText != ''", arguments: StatementArguments(ids))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["recognizedText"] as String) })
        }
    }

    /// Settings › Privacy: forgets every recognized text. The images stay.
    func clearRecognizedText() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clip SET recognizedText = NULL, recognizedLayout = NULL, recognizedSearch = NULL WHERE recognizedText IS NOT NULL")
        }
    }

    func clip(id: Int64) throws -> Clip? {
        try dbQueue.read { db in try Clip.fetchOne(db, key: id) }
    }

    /// Records a copy made from the panel.
    func bump(id: Int64, at date: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clip SET timesCopied = timesCopied + 1, lastCopiedAt = ? WHERE id = ?",
                arguments: [date, id]
            )
        }
    }

    func setPinned(id: Int64, _ pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clip SET pinned = ? WHERE id = ?", arguments: [pinned, id])
        }
    }

    func delete(id: Int64) throws {
        let file: String? = try dbQueue.write { db in
            let clip = try Clip.fetchOne(db, key: id)
            _ = try Clip.deleteOne(db, key: id)
            return clip?.imageFile
        }
        deleteImageFiles([file].compactMap { $0 })
    }

    /// Deletes unpinned clips copied at or after `since`, or all unpinned clips when `since` is nil.
    func clear(since: Date?) throws {
        let files: [String] = try dbQueue.write { db in
            var request = Clip.filter(Column("pinned") == false && Column("snippetName") == nil && Column("kind") != ClipKind.secret.rawValue)
            if let since { request = request.filter(Column("lastCopiedAt") >= since) }
            let files = try String.fetchAll(db, request.select(Column("imageFile")).filter(Column("imageFile") != nil))
            _ = try request.deleteAll(db)
            return files
        }
        deleteImageFiles(files)
    }

    /// Applies the retention period, item limit and size limit. Pinned clips are never removed.
    /// Reads only id, image file and size, so pruning a large history stays cheap.
    @discardableResult
    func prune(_ limits: PruneLimits, now: Date = Date()) throws -> Int {
        let (removed, files) = try dbQueue.write { db in try Self.prune(db, limits, now: now) }
        deleteImageFiles(files)
        return removed
    }

    /// How many clips `prune` would remove now. Runs the same deletes and rolls them back.
    func pruneCount(_ limits: PruneLimits, now: Date = Date()) throws -> Int {
        var count = 0
        try dbQueue.inTransaction { db in
            count = try Self.prune(db, limits, now: now).removed
            return .rollback
        }
        return count
    }

    /// How many clips `clear(since:)` would remove.
    func clearCount(since: Date?) throws -> Int {
        try dbQueue.read { db in
            var request = Clip.filter(Column("pinned") == false && Column("snippetName") == nil && Column("kind") != ClipKind.secret.rawValue)
            if let since { request = request.filter(Column("lastCopiedAt") >= since) }
            return try request.fetchCount(db)
        }
    }

    private nonisolated static func prune(_ db: Database, _ limits: PruneLimits, now: Date) throws -> (removed: Int, files: [String]) {
        var removed = 0
        var files: [String] = []
        func remove(_ rows: [Row]) throws {
            guard !rows.isEmpty else { return }
            files += rows.compactMap { $0["imageFile"] as String? }
            // In parts: one statement with tens of thousands of ids would pass SQLite's limit.
            let ids = rows.map { $0["id"] as Int64 }
            for start in stride(from: 0, to: ids.count, by: 500) {
                removed += try Clip.deleteAll(db, keys: Array(ids[start..<min(start + 500, ids.count)]))
            }
        }
        // Kept: pinned items, snippets and Hidden items (those set to expire go by `expiresAt`).
        let kept = "pinned = 0 AND snippetName IS NULL AND kind != 'secret'"
        let oldestFirst = "SELECT id, imageFile, byteSize FROM clip WHERE \(kept) ORDER BY lastCopiedAt ASC"

        // Hidden items set to delete themselves.
        try remove(Row.fetchAll(db, sql: "SELECT id, imageFile FROM clip WHERE expiresAt IS NOT NULL AND expiresAt <= ?", arguments: [now]))

        if limits.retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(limits.retentionDays) * 86_400)
            try remove(Row.fetchAll(db, sql: "SELECT id, imageFile FROM clip WHERE \(kept) AND lastCopiedAt < ?", arguments: [cutoff]))
        }
        if limits.maxItems > 0 {
            let total = try Clip.fetchCount(db)
            if total > limits.maxItems {
                try remove(Row.fetchAll(db, sql: oldestFirst + " LIMIT ?", arguments: [total - limits.maxItems]))
            }
        }
        if limits.maxBytes > 0 {
            var total = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM clip") ?? 0
            if total > limits.maxBytes {
                var victims: [Row] = []
                do { // The cursor ends before the delete runs.
                    let cursor = try Row.fetchCursor(db, sql: oldestFirst)
                    while total > limits.maxBytes, let row = try cursor.next() {
                        victims.append(row.copy())
                        total -= row["byteSize"] as Int
                    }
                }
                try remove(victims)
            }
        }
        return (removed, files)
    }

    private func deleteImageFiles(_ names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Reading

    /// The newest `limit` items of a group, optionally filtered by a search. The search always
    /// stays inside the group.
    ///
    /// Two steps keep this fast with large histories: the inner query picks the ids from indexes
    /// and small columns only; the outer query then reads list columns for those ids alone.
    func fetch(category: ClipCategory, query: String, app: SourceApp? = nil, limit: Int) throws -> [Clip] {
        try dbQueue.read { db in
            var conditions: [String] = []
            var arguments = StatementArguments()

            // "@Arc": only what was copied in that app.
            if let app {
                if let bundleID = app.bundleID {
                    conditions.append("sourceBundleID = ?")
                    _ = arguments.append(contentsOf: [bundleID])
                } else {
                    conditions.append("sourceAppName = ?")
                    _ = arguments.append(contentsOf: [app.name])
                }
            }

            if category == .screenshots {
                conditions.append("kind = 'image' AND sourceBundleID = '\(Clip.screenshotSource)'")
            } else if category == .images {
                // Images also holds copied image files (they stay in Files too).
                conditions.append("(kind = 'image' OR (kind = 'file' AND format = '\(Clip.imageFilesFormat)'))")
            } else if let kinds = category.kinds {
                conditions.append("kind IN (" + kinds.map { _ in "?" }.joined(separator: ", ") + ")")
                _ = arguments.append(contentsOf: StatementArguments(kinds.map(\.rawValue)))
            }
            if category.kinds == nil {
                conditions.append("kind != 'secret'") // Hidden items appear only in Hidden.
            }
            if category == .snippets {
                conditions.append("snippetName IS NOT NULL")
            }
            if category == .pinned {
                conditions.append("pinned = 1")
            }

            let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
            // Terms of 3 or more characters use the trigram index; all of them must match.
            let indexed = terms.filter { $0.count >= 3 }
            if !indexed.isEmpty {
                func quoted(_ term: String) -> String { "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                // Each word as typed, or folded ("yılmaz" also finds text read as "yilmaz").
                let match = indexed
                    .map { term in
                        let folded = term.searchFolded
                        return folded == term.lowercased() ? quoted(term) : "(" + quoted(term) + " OR " + quoted(folded) + ")"
                    }
                    .joined(separator: " AND ")
                conditions.append("id IN (SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?)")
                _ = arguments.append(contentsOf: [match])
            }
            // Shorter terms (trigrams need 3 characters) are checked with LIKE on the remaining rows.
            for term in terms where term.count < 3 {
                let pattern = "%" + Self.escapeLike(term) + "%"
                let folded = "%" + Self.escapeLike(term.searchFolded) + "%"
                conditions.append("(searchText LIKE ? ESCAPE '\\' OR sourceAppName LIKE ? ESCAPE '\\' OR recognizedSearch LIKE ? ESCAPE '\\')")
                _ = arguments.append(contentsOf: [pattern, pattern, folded])
            }

            let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            _ = arguments.append(contentsOf: [limit])
            let sql = """
                SELECT \(Self.listColumns) FROM clip
                WHERE id IN (SELECT id FROM clip \(filter) ORDER BY lastCopiedAt DESC LIMIT ?)
                ORDER BY lastCopiedAt DESC
                """
            return try Clip.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    func counts() throws -> [ClipCategory: Int] {
        try dbQueue.read { db in
            var byKind: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM clip GROUP BY kind") {
                byKind[row["kind"]] = row["n"]
            }
            let pinned = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip WHERE pinned = 1 AND kind != 'secret'") ?? 0
            let snippets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip WHERE snippetName IS NOT NULL") ?? 0
            let imageFiles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip WHERE kind = 'file' AND format = ?",
                                              arguments: [Clip.imageFilesFormat]) ?? 0
            let screenshots = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip WHERE kind = 'image' AND sourceBundleID = ?",
                                               arguments: [Clip.screenshotSource]) ?? 0
            var result: [ClipCategory: Int] = [:]
            for category in ClipCategory.allCases {
                if category == .snippets {
                    result[category] = snippets
                } else if category == .pinned {
                    result[category] = pinned
                } else if category == .screenshots {
                    result[category] = screenshots
                } else if let kinds = category.kinds {
                    result[category] = kinds.reduce(0) { $0 + (byKind[$1.rawValue] ?? 0) } + (category == .images ? imageFiles : 0)
                } else {
                    result[category] = byKind.filter { $0.key != ClipKind.secret.rawValue }.values.reduce(0, +)
                }
            }
            return result
        }
    }

    func usage() throws -> StoreUsage {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c,
                       COALESCE(SUM(byteSize), 0) AS t,
                       COALESCE(SUM(CASE WHEN kind = 'image' THEN byteSize ELSE 0 END), 0) AS i
                FROM clip
                """)
            return StoreUsage(count: row?["c"] ?? 0, totalBytes: row?["t"] ?? 0, imageBytes: row?["i"] ?? 0)
        }
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
