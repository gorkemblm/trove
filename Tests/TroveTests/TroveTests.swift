import AppKit
import Foundation
import Testing
import GRDB
@testable import Trove

struct ClassifierTests {
    @Test func testLinks() {
        #expect(ClipClassifier.isLink("https://github.com/groue/GRDB.swift"))
        #expect(ClipClassifier.isLink("www.apple.com"))
        #expect(!(ClipClassifier.isLink("github.com is great")))
        #expect(!(ClipClassifier.isLink("file:///etc/hosts")))
        #expect(!(ClipClassifier.isLink("hello")))
    }

    @Test func testColors() {
        XCTAssertEqual(RGBA(parsing: "#D97757"), RGBA(r: 217, g: 119, b: 87))
        XCTAssertEqual(RGBA(parsing: "#fff"), RGBA(r: 255, g: 255, b: 255))
        XCTAssertEqual(RGBA(parsing: "rgb(1, 2, 3)"), RGBA(r: 1, g: 2, b: 3))
        #expect((RGBA(parsing: "#12345")) == nil)
        #expect((RGBA(parsing: "rgb(300, 0, 0)")) == nil)
        #expect(ClipClassifier.isColor("#4C8DFF"))
        #expect(!(ClipClassifier.isColor("#hashtag")))
    }

    @Test func colorForms() throws {
        let orange = try #require(RGBA(parsing: "#D97757"))
        #expect(orange.hex == "#D97757")
        #expect(orange.rgbString == "rgb(217, 119, 87)")
        #expect(orange.hslString == "hsl(15, 63%, 60%)")
        #expect(RGBA(parsing: "#000000")?.hslString == "hsl(0, 0%, 0%)")
        #expect(RGBA(parsing: "#FFFFFF")?.hslString == "hsl(0, 0%, 100%)")
        #expect(RGBA(parsing: "#00FF00")?.hslString == "hsl(120, 100%, 50%)")
        #expect(RGBA(parsing: "#3366CC")?.hslString == "hsl(220, 60%, 50%)")
    }

    @Test func testTextKinds() {
        XCTAssertEqual(ClipClassifier.textContent("  https://apple.com \n", rtf: nil).kind, .link)
        XCTAssertEqual(ClipClassifier.textContent("#D97757", rtf: nil).kind, .color)
        let text = ClipClassifier.textContent("Toplantı Perşembe 14:00'te başlıyor", rtf: nil)
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.text, "Toplantı Perşembe 14:00'te başlıyor")
    }

    @Test func testSameTextSameHash() {
        XCTAssertEqual(ClipClassifier.textContent("abc", rtf: nil).hash, ClipClassifier.textContent("abc", rtf: nil).hash)
        #expect(ClipClassifier.textContent("abc", rtf: nil).hash != ClipClassifier.textContent("abd", rtf: nil).hash)
    }
}

@MainActor
struct StoreTests {
    private let store: Store
    private let arc = ClipSource(bundleID: "company.thebrowser.Browser", appName: "Arc", url: nil)

    init() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try Store.inMemory(imagesDirectory: tempDir.appendingPathComponent("Images"))
    }

    @discardableResult
    private func add(_ text: String, at date: Date = Date(), source: ClipSource? = nil) throws -> Clip {
        try store.ingest(ClipClassifier.textContent(text, rtf: nil), source: source ?? arc, at: date)
    }

    @Test func testDuplicateMovesToTopAndCounts() throws {
        let first = try add("hello", at: Date(timeIntervalSinceNow: -100))
        try add("other", at: Date(timeIntervalSinceNow: -50))
        let again = try add("hello", at: Date())
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(again.timesCopied, 2)
        let all = try store.fetch(category: .all, query: "", limit: 10)
        XCTAssertEqual(all.map(\.text), ["hello", "other"])
        #expect(abs((all.first?.firstCopiedAt.timeIntervalSince1970 ?? 0) - first.firstCopiedAt.timeIntervalSince1970) < 0.01)
    }

    @Test func testCategoriesAndCounts() throws {
        try add("plain text")
        try add("https://example.com/page")
        try add("#D97757")
        XCTAssertEqual(try store.fetch(category: .links, query: "", limit: 10).count, 1)
        XCTAssertEqual(try store.fetch(category: .text, query: "", limit: 10).count, 2) // text + colour
        let counts = try store.counts()
        XCTAssertEqual(counts[.all], 3)
        XCTAssertEqual(counts[.links], 1)
        XCTAssertEqual(counts[.images], 0)
    }

    @Test func testSearch() throws {
        try add("ssh deploy@10.0.4.12 -p 2222")
        try add("https://github.com/sindresorhus/KeyboardShortcuts")
        try add("Toplantı Perşembe 14:00'te başlıyor")
        // Substring, case-insensitive (trigram).
        XCTAssertEqual(try store.fetch(category: .all, query: "HUB", limit: 10).count, 1)
        XCTAssertEqual(try store.fetch(category: .all, query: "deploy 2222", limit: 10).count, 1)
        // Short terms fall back to LIKE.
        XCTAssertEqual(try store.fetch(category: .all, query: "-p", limit: 10).count, 1)
        // Non-ASCII text.
        XCTAssertEqual(try store.fetch(category: .all, query: "perşembe", limit: 10).count, 1)
        // Source app name.
        XCTAssertEqual(try store.fetch(category: .all, query: "arc", limit: 10).count, 3)
        // Quotes in the query do not break the FTS syntax.
        XCTAssertEqual(try store.fetch(category: .all, query: "\"oops", limit: 10).count, 0)
        XCTAssertEqual(try store.fetch(category: .links, query: "deploy", limit: 10).count, 0)
    }

    @Test func testPruneKeepsPinned() throws {
        let old = try add("old", at: Date(timeIntervalSinceNow: -40 * 86_400))
        let pinnedOld = try add("pinned old", at: Date(timeIntervalSinceNow: -40 * 86_400))
        try store.setPinned(id: pinnedOld.id!, true)
        try add("new")
        let removed = try store.prune(PruneLimits(retentionDays: 30, maxItems: 0, maxBytes: 0))
        XCTAssertEqual(removed, 1)
        let texts = try store.fetch(category: .all, query: "", limit: 10).compactMap(\.text)
        #expect(!(texts.contains(old.text!)))
        #expect(texts.contains("pinned old"))
    }

    @Test func testPruneMaxItemsAndBytes() throws {
        for i in 0..<10 { try add("item \(i)", at: Date(timeIntervalSinceNow: Double(i))) }
        try store.prune(PruneLimits(retentionDays: 0, maxItems: 6, maxBytes: 0))
        XCTAssertEqual(try store.fetch(category: .all, query: "", limit: 50).count, 6)
        // Each "item N" is 6 bytes. 24 bytes keep 4 items.
        try store.prune(PruneLimits(retentionDays: 0, maxItems: 0, maxBytes: 24))
        let remaining = try store.fetch(category: .all, query: "", limit: 50).compactMap(\.text)
        XCTAssertEqual(remaining, ["item 9", "item 8", "item 7", "item 6"])
    }

    @Test func testClearKeepsPinned() throws {
        let keep = try add("keep me")
        try store.setPinned(id: keep.id!, true)
        try add("drop me")
        try store.clear(since: nil)
        XCTAssertEqual(try store.fetch(category: .all, query: "", limit: 10).compactMap(\.text), ["keep me"])
    }

    /// Acceptance criterion from the plan: search in 10,000 items takes under 50 ms.
    @Test func testSearchSpeedWith10kItems() throws {
        let words = ["deploy", "meeting", "invoice", "github", "screenshot", "toplantı", "kubernetes", "password", "design", "review"]
        for i in 0..<10_000 {
            let text = "\(words[i % words.count]) note \(i) " + String(repeating: "lorem ipsum ", count: i % 20)
            try add(text, at: Date(timeIntervalSinceNow: Double(-i)))
        }
        let report = try betterOfTwo(limit: .milliseconds(50)) {
            try ["kubernetes", "note 99", "ipsum", "toplantı", "zzz-no-match", "de"].map { query in
                (query, try measure { _ = try store.fetch(category: .all, query: query, limit: PanelModel.fetchLimit) }.median)
            }
        }
        for (query, median) in report { print("  10k search '\(query)': median \(median.ms)") }
        let worst = report.map(\.1).max() ?? .zero
        print("Worst median search time over 10,000 items: \(worst.ms)")
        #expect(worst < .milliseconds(50))
    }
}

/// Equality check with XCTest-style call sites.
func XCTAssertEqual<T: Equatable>(
    _ a: @autoclosure () throws -> T,
    _ b: @autoclosure () throws -> T,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let x = try a(), y = try b()
        #expect(x == y, sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

struct StorageLocationTests {
    @Test func createsHistoryFolderInsidePickedLocation() {
        let picked = URL(fileURLWithPath: "/Users/me/Documents")
        let result = StorageLocation.historyFolder(for: picked, fileExists: { _ in false })
        #expect(result.path == "/Users/me/Documents/Trove History")
        // Own folder off: the files go straight into the picked folder.
        #expect(StorageLocation.historyFolder(for: picked, subfolder: false, fileExists: { _ in false }) == picked)
        #expect(StorageLocation.location(of: result).path == picked.path)
        #expect(StorageLocation.location(of: picked) == picked)
    }

    @Test func reusesFolderThatAlreadyHoldsHistory() {
        let picked = URL(fileURLWithPath: "/Users/me/Old")
        let result = StorageLocation.historyFolder(for: picked, fileExists: { $0.hasSuffix("/Old/clipboard.sqlite") })
        #expect(result == picked)
        let named = URL(fileURLWithPath: "/Users/me/Clipboard History")
        #expect(StorageLocation.historyFolder(for: named, fileExists: { _ in false }) == named)
        let renamed = URL(fileURLWithPath: "/Users/me/Trove History")
        #expect(StorageLocation.historyFolder(for: renamed, fileExists: { _ in false }) == renamed)
    }

    @Test func detectsSyncedFolders() {
        #expect(StorageLocation.syncProvider(for: URL(fileURLWithPath: "/Users/me/Seafile/Active/x")) == "Seafile")
        #expect(StorageLocation.syncProvider(for: URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/x")) == "iCloud Drive")
        #expect(StorageLocation.syncProvider(for: URL(fileURLWithPath: "/Users/me/Documents/x")) == nil)
    }
}

/// Behaviour and speed with a large, mixed history: 30,000 items, of which 300 are 200 KB texts
/// (60 MB of text), plus links, colours, files and image records.
@MainActor
struct ScaleTests {
    private let store: Store
    private let ids: [String: Int64]

    init() throws {
        // An encrypted database on disk, as in the app: SQLCipher decrypts every page it reads.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try Store.open(directory: tempDir, key: .random())
        var ids: [String: Int64] = [:]
        let big = String(repeating: "lorem ipsum dolor sit amet kubernetes deploy ", count: 4_500) // ~200 KB
        let now = Date()
        var clips: [Clip] = []
        for i in 0..<30_000 {
            let text: String
            let kind: ClipKind
            switch i % 10 {
            case 0: kind = .link; text = "https://example.com/project/\(i)/deploy"
            case 1: kind = .color; text = String(format: "#%06X", i * 2654435 % 0xFFFFFF)
            case 2: kind = .file; text = "/Users/me/Documents/report-\(i).pdf"
            case 3: kind = .image; text = ""
            default:
                kind = .text
                text = i % 100 == 4 ? big + "\(i)" : "meeting note \(i) about deploy and invoices"
            }
            let clip = Clip(
                id: nil, kind: kind, text: kind == .image ? nil : text, rtf: nil,
                imageFile: kind == .image ? "img\(i).png" : nil, imageWidth: 100, imageHeight: 100,
                fileSize: nil, byteSize: text.utf8.count, contentHash: "h\(i)",
                sourceBundleID: "app.\(i % 7)", sourceAppName: "App \(i % 7)", sourceURL: nil,
                pinned: i % 997 == 0, timesCopied: 1,
                firstCopiedAt: now.addingTimeInterval(Double(-i)), lastCopiedAt: now.addingTimeInterval(Double(-i))
            )
            clips.append(clip)
        }
        let saved = try store.insert(clips)
        ids["big"] = saved[4].id
        self.ids = ids
    }

    private func time(_ work: () throws -> Void) rethrows -> Duration {
        try measure(work).median
    }

    /// One test, so the 30,000-item store is built once.
    @Test func largeHistory() throws {
        try searchStaysInsideTheSelectedGroup()
        try listLoadsPreviewButCopyGetsFullText()
        try speedWith30kItems()
    }

    private func searchStaysInsideTheSelectedGroup() throws {
        let links = try store.fetch(category: .links, query: "deploy", limit: 50_000)
        #expect(!links.isEmpty)
        #expect(links.allSatisfy { $0.kind == .link })
        let files = try store.fetch(category: .files, query: "report", limit: 50_000)
        #expect(files.count == 3_000)
        #expect(files.allSatisfy { $0.kind == .file })
        let texts = try store.fetch(category: .text, query: "deploy", limit: 50_000)
        #expect(texts.allSatisfy { $0.kind == .text || $0.kind == .color })
        #expect(try store.fetch(category: .images, query: "deploy", limit: 50_000).isEmpty)
        let pinned = try store.fetch(category: .pinned, query: "", limit: 50_000)
        #expect(pinned.allSatisfy { $0.pinned })
    }

    private func listLoadsPreviewButCopyGetsFullText() throws {
        let id = try #require(ids["big"])
        let page = try store.fetch(category: .text, query: "", limit: 50_000)
        let listed = try #require(page.first { $0.id == id })
        #expect(listed.text?.count == Store.listCharacters)
        let fetched = try store.clip(id: id)
        let full = try #require(fetched)
        #expect(full.text!.count > 200_000)
        // Counts come from the full text, not the preview.
        #expect(listed.characterCount == full.text!.count)
    }

    private func speedWith30kItems() throws {
        func run() throws -> [(String, Duration)] {
            var report: [(String, Duration)] = []
            report.append(("open panel: All, latest 2,000", try time { _ = try store.fetch(category: .all, query: "", limit: PanelModel.fetchLimit) }))
            report.append(("open panel: Text, latest 2,000", try time { _ = try store.fetch(category: .text, query: "", limit: PanelModel.fetchLimit) }))
            report.append(("group counts", try time { _ = try store.counts() }))
            for (category, query) in [(ClipCategory.all, "kubernetes"), (.text, "deploy"), (.links, "deploy"),
                                      (.files, "report-29"), (.images, "x"), (.all, "zzzz-none"), (.all, "app 3")] {
                report.append(("search \(category.title) '\(query)'",
                               try time { _ = try store.fetch(category: category, query: query, limit: PanelModel.fetchLimit) }))
            }
            return report
        }
        let report = try betterOfTwo(limit: .milliseconds(50), run)
        for (name, duration) in report {
            print("  \(name): \(duration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        }
        let worst = report.map(\.1).max() ?? .zero
        print("Worst median with 30,000 items: \(worst.ms)")
        #expect(worst < .milliseconds(50))
    }
}

/// A history saved by version 0.1 (schema v1, unencrypted, plain PNG files) opens in the current
/// version without data loss, and is encrypted on the way.
@MainActor
struct MigrationTests {
    @Test func upgradesAndEncryptsV1History() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        let images = dir.appendingPathComponent(Store.imagesFolderName)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("fake image body".utf8)
        try png.write(to: images.appendingPathComponent("c.png"))
        let path = dir.appendingPathComponent(Store.databaseFileName).path
        do {
            let queue = try DatabaseQueue(path: path)
            try Store.migrator.migrate(queue, upTo: "v1-clips")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO clip (kind, text, byteSize, contentHash, sourceAppName, pinned, timesCopied, firstCopiedAt, lastCopiedAt)
                    VALUES ('text', 'Toplantı Perşembe\nikinci satır', 30, 'a', 'Telegram', 1, 3, '2026-11-20 10:00:00.000', '2026-11-25 10:00:00.000'),
                           ('link', 'https://github.com/groue/GRDB.swift', 35, 'b', 'Arc', 0, 1, '2026-11-25 11:00:00.000', '2026-11-25 11:00:00.000');
                    INSERT INTO clip (kind, imageFile, imageWidth, imageHeight, byteSize, contentHash, firstCopiedAt, lastCopiedAt)
                    VALUES ('image', 'c.png', 1, 1, 23, 'c', '2026-11-24 10:00:00.000', '2026-11-24 10:00:00.000')
                    """)
            }
            try queue.close()
        }
        #expect(Store.isPlaintextDatabase(URL(fileURLWithPath: path)))

        let vault = Vault(keyStore: MemoryKeyStore(), iterations: 1_000)
        guard case .ready(let key) = try vault.prepare(directory: dir) else {
            Issue.record("An unencrypted history must get a new key")
            return
        }
        let store = try Store.open(directory: dir, key: key, originals: .keepInFolder)
        #expect(!Store.isPlaintextDatabase(URL(fileURLWithPath: path)))
        // Nothing is deleted: the unencrypted originals wait in a backup folder.
        let backup = try #require(store.unencryptedBackup)
        #expect(Store.isPlaintextDatabase(backup.appendingPathComponent(Store.databaseFileName)))
        #expect(try Data(contentsOf: backup.appendingPathComponent("Images/c.png")) == png)
        #expect(Store.hasEncryptedData(in: dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Store.encryptingFileName).path))

        let all = try store.fetch(category: .all, query: "", limit: 10)
        #expect(all.count == 3)
        #expect(all.first?.kind == .link)
        let text = try #require(all.first { $0.kind == .text })
        #expect(text.pinned)
        #expect(text.timesCopied == 3)
        #expect(text.wordCount == 4)
        #expect(text.lineCount == 2)
        #expect(try store.fetch(category: .all, query: "perşembe", limit: 10).count == 1)
        #expect(try store.fetch(category: .links, query: "grdb", limit: 10).count == 1)
        #expect(try store.fetch(category: .all, query: "telegram", limit: 10).count == 1)

        // The plain PNG is replaced by an encrypted file with a random name.
        let image = try #require(all.first { $0.kind == .image })
        #expect(image.imageFile?.hasSuffix(".enc") == true)
        #expect(!FileManager.default.fileExists(atPath: images.appendingPathComponent("c.png").path))
        #expect(store.imageData(for: image) == png)
        let sealed = try Data(contentsOf: images.appendingPathComponent(try #require(image.imageFile)))
        #expect(sealed.range(of: Data("fake image body".utf8)) == nil)

        // New items still work after the upgrade.
        try store.ingest(ClipClassifier.textContent("after upgrade", rtf: nil), source: ClipSource(), at: Date())
        #expect(try store.fetch(category: .text, query: "upgrade", limit: 10).count == 1)
        // A later open still reports a backup that was left behind (an interrupted first open).
        try store.close()
        let reopened = try Store.open(directory: dir, key: key, originals: .keepInFolder)
        #expect(reopened.unencryptedBackup == backup)
    }

    /// v4: text saved before content types moves to Code, Emails and Phones, and keeps merging.
    @Test func sortsExistingTextIntoContentTypes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(Store.databaseFileName).path
        let key = DataKey.random()
        do {
            var config = Configuration()
            let passphrase = key.databasePassphrase
            config.prepareDatabase { db in try db.usePassphrase(passphrase) }
            let queue = try DatabaseQueue(path: path, configuration: config)
            try Store.migrator.migrate(queue, upTo: "v3-hidden")
            try queue.write { db in
                for (text, hash, minutes) in [("ali@example.com", "h1", 1), ("ali@example.com\n", "h2", 2),
                                              ("+90 532 123 45 67", "h3", 3), ("git status", "h4", 4),
                                              ("Toplantı yarın", "h5", 5)] {
                    try db.execute(sql: """
                        INSERT INTO clip (kind, text, searchText, byteSize, contentHash, pinned, timesCopied, firstCopiedAt, lastCopiedAt)
                        VALUES ('text', ?, ?, 10, ?, 0, 1, ?, ?)
                        """, arguments: [text, text, hash, Date(timeIntervalSinceNow: Double(-minutes * 60)), Date(timeIntervalSinceNow: Double(-minutes * 60))])
                }
            }
            try queue.close()
        }
        let store = try Store.open(directory: dir, key: key, originals: .keepInFolder)
        let counts = try store.counts()
        #expect(counts[.emails] == 1) // The second spelling of the same address stays text.
        #expect(counts[.phones] == 1)
        #expect(counts[.code] == 1)
        #expect(counts[.text] == 5) // Text still shows everything.
        #expect(try store.fetch(category: .emails, query: "ali", limit: 10).first?.text == "ali@example.com")

        // A new copy of the same address merges with the sorted item.
        let again = try store.ingest(ClipClassifier.textContent("ali@example.com", rtf: nil), source: ClipSource(), at: Date())
        #expect(again.kind == .email)
        #expect(again.timesCopied == 2)
        #expect(try store.counts()[.emails] == 1)
    }
}

/// Changes that delete items can be counted first, without deleting anything.
@MainActor
struct DeletionPreviewTests {
    @Test func countsMatchWhatPruneAndClearDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        let now = Date()
        for day in 0..<10 {
            try store.ingest(ClipClassifier.textContent("day \(day)", rtf: nil), source: ClipSource(),
                             at: now.addingTimeInterval(-Double(day) * 86_400 - 60))
        }
        let pinned = try store.fetch(category: .all, query: "day 9", limit: 1)[0]
        try store.setPinned(id: try #require(pinned.id), true)

        let week = PruneLimits(retentionDays: 7, maxItems: 0, maxBytes: 0)
        #expect(try store.pruneCount(week, now: now) == 2) // days 7 and 8; day 9 is pinned
        #expect(try store.pruneCount(PruneLimits(retentionDays: 7, maxItems: 5, maxBytes: 0), now: now) == 5)
        #expect(try store.counts()[.all] == 10) // Counting deleted nothing.

        #expect(try store.clearCount(since: now.addingTimeInterval(-3600)) == 1)
        #expect(try store.clearCount(since: nil) == 9)
        #expect(try store.counts()[.all] == 10)

        #expect(try store.prune(week, now: now) == 2)
        #expect(try store.counts()[.all] == 8)
    }
}

/// Screenshots saved as files: new images are reported once, older files and other files are not.
@MainActor
struct ScreenshotWatcherTests {
    @Test func reportsOnlyNewImages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("Old screenshot.png"))

        var reported: [String] = []
        let watcher = ScreenshotWatcher(directory: dir) { reported.append($0.lastPathComponent) }
        #expect(watcher.start())

        // As macOS does: a hidden temporary file, then a rename.
        let temp = dir.appendingPathComponent(".Screenshot 2026-11-25 at 22.10.00.png")
        try Data([2]).write(to: temp)
        try FileManager.default.moveItem(at: temp, to: dir.appendingPathComponent("Screenshot 2026-11-25 at 22.10.00.png"))
        try Data([3]).write(to: dir.appendingPathComponent("notes.txt"))
        try await Task.sleep(for: .seconds(ScreenshotWatcher.settleDelay + 0.8))

        #expect(reported == ["Screenshot 2026-11-25 at 22.10.00.png"])
        watcher.stop()
    }

    @Test func screenshotsKeepTheirFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data("pixels".utf8)
        var content = CapturedContent(kind: .image, imageData: png, imageWidth: 2, imageHeight: 2, byteSize: png.count,
                                      hash: ClipClassifier.hash("image", png))
        content.text = "/Users/me/Shots/Screenshot 2026-11-25 at 22.15.45.png"
        let saved = try store.ingest(content, source: ClipSource(appName: "Screenshot"), at: Date())

        let listed = try #require(try store.fetch(category: .images, query: "22.15", limit: 10).first)
        #expect(listed.title == "Screenshot 2026-11-25 at 22.15.45")
        #expect(listed.revealPaths.isEmpty) // List items carry only the file name.
        let savedID = try #require(saved.id)
        let full = try #require(try store.clip(id: savedID))
        #expect(full.revealPaths == ["/Users/me/Shots/Screenshot 2026-11-25 at 22.15.45.png"])

        // The same image saved again (moved or copied): one item, newest path.
        content.text = "/Users/me/Archive/Screenshot 2026-11-25 at 22.15.45.png"
        try store.ingest(content, source: ClipSource(appName: "Screenshot"), at: Date())
        #expect(try store.counts()[.images] == 1)
        #expect(try store.clip(id: savedID)?.revealPaths == ["/Users/me/Archive/Screenshot 2026-11-25 at 22.15.45.png"])

        // An image from the clipboard has no file.
        let copied = CapturedContent(kind: .image, imageData: png + Data([1]), imageWidth: 2, imageHeight: 2, byteSize: 9,
                                     hash: ClipClassifier.hash("image", png + Data([1])))
        let pasted = try store.ingest(copied, source: ClipSource(appName: "Preview"), at: Date())
        let pastedID = try #require(pasted.id)
        #expect(try store.clip(id: pastedID)?.revealPaths == [])
    }

    @Test func convertsOtherFormatsToPNG() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try #require(rep.representation(using: .jpeg, properties: [:]))
        let content = try #require(ClipClassifier.imageContent(data: jpeg, maxBytes: 1_048_576))
        #expect(content.imageData?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
        #expect(content.imageWidth == 4 && content.imageHeight == 3)
        #expect(ClipClassifier.imageContent(data: Data("not an image".utf8), maxBytes: 1_048_576) == nil)
        #expect(ClipClassifier.imageContent(data: jpeg, maxBytes: 10) == nil)
    }
}

/// Where the arrow keys act when the panel opens or the group changes.
@MainActor
struct PanelFocusTests {
    /// The panel model holds its app weakly; the test keeps the app alive.
    private let app = AppModel()

    private func makeModel() throws -> (PanelModel, Store) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        return (app.panelModel, store)
    }

    @Test func emptyGroupKeepsArrowsInTheSidebar() throws {
        let (model, store) = try makeModel()
        model.willShow()
        #expect(model.focusArea == .sidebar) // Nothing copied yet.

        try store.ingest(ClipClassifier.textContent("hello", rtf: nil), source: ClipSource(), at: Date())
        model.willShow()
        #expect(model.focusArea == .list)

        model.selectCategory(number: 5) // Files: empty
        #expect(model.focusArea == .sidebar)
        model.focusList()
        #expect(model.focusArea == .sidebar) // → does not leave an empty group.

        model.selectCategory(number: 1)
        model.focusList()
        #expect(model.focusArea == .list)
    }

    @Test func groupsTurnedOffLeaveTheSidebarOnly() throws {
        let (model, store) = try makeModel()
        try store.ingest(ClipClassifier.textContent("/Users/me/a.txt", rtf: nil), source: ClipSource(), at: Date())
        app.settings.hiddenGroups = [ClipCategory.files.rawValue, ClipCategory.code.rawValue]
        defer { app.settings.hiddenGroups = [] }
        #expect(!model.visibleGroups.contains(.files))
        #expect(!model.visibleGroups.contains(.code))
        model.selectCategory(number: 5) // Files is off: nothing changes.
        #expect(model.category == .all)
        model.category = .screenshots
        model.moveCategory(1) // Screenshots → Pinned, skipping Files.
        #expect(model.category == .pinned)
        model.category = .files
        model.willShow() // A group turned off while selected falls back to All.
        #expect(model.category == .all)
    }

    @Test func pausedRecordingSavesNothing() throws {
        let (model, store) = try makeModel()
        _ = model
        app.pauseRecording(minutes: 10)
        app.ingest(ClipClassifier.textContent("while paused", rtf: nil), source: ClipSource())
        #expect(try store.counts()[.all] == 0)
        #expect(app.pauseDescription?.hasPrefix("Paused until") == true)
        app.resumeRecording()
        app.ingest(ClipClassifier.textContent("after resume", rtf: nil), source: ClipSource())
        #expect(try store.counts()[.all] == 1)
        app.pauseRecording(minutes: nil)
        #expect(app.pauseDescription == "Recording paused")
        app.resumeRecording()
    }

    @Test func lockedPanelHoldsNoHistory() throws {
        let (model, store) = try makeModel()
        try store.ingest(ClipClassifier.textContent("private note", rtf: nil), source: ClipSource(), at: Date())
        model.willShow()
        #expect(model.clips.count == 1)
        model.setPanelLocked(true)
        #expect(model.clips.isEmpty && model.sections.isEmpty && model.detail == nil)
        model.reload(resetSelection: true) // A change in the store while locked loads nothing.
        #expect(model.clips.isEmpty)
        model.setPanelLocked(false)
        #expect(model.clips.count == 1)
    }

    @Test func searchKeepsArrowsWithTheResults() throws {
        let (model, store) = try makeModel()
        try store.ingest(ClipClassifier.textContent("hello", rtf: nil), source: ClipSource(), at: Date())
        model.willShow()
        model.query = "no match at all"
        #expect(model.focusArea == .list)
    }

    @Test func deletingTheLastItemMovesToTheSidebar() throws {
        let (model, store) = try makeModel()
        try store.ingest(ClipClassifier.textContent("only item", rtf: nil), source: ClipSource(), at: Date())
        model.willShow()
        #expect(model.focusArea == .list)
        model.requestDelete()
        model.confirmDelete()
        #expect(model.focusArea == .sidebar)
    }
}

/// Content types inside Text: what must be recognised, and ordinary text that must stay text.
struct ContentDetectorTests {
    @Test func emails() {
        #expect(ContentDetector.emailAddresses(in: "ali@example.com") == ["ali@example.com"])
        #expect(ContentDetector.emailAddresses(in: " ayse.yilmaz+work@mail.co.uk \n") == ["ayse.yilmaz+work@mail.co.uk"])
        #expect(ContentDetector.emailAddresses(in: "a@b.io, c@d.com; e@f.org") == ["a@b.io", "c@d.com", "e@f.org"])
        #expect(ContentDetector.emailAddresses(in: "mailto:hello@iokoda.co.uk") == ["hello@iokoda.co.uk"])
        for text in ["Mail at ali@example.com please", "@ali", "ali@", "ali@localhost", "user@@x.com", "a@b.c",
                     "foo@bar.com is my mail", "https://x.com/@user"] {
            #expect(ContentDetector.emailAddresses(in: text) == nil, "\(text)")
        }
    }

    @Test func phones() {
        #expect(ContentDetector.phoneNumber(in: "+90 532 123 45 67") == "+905321234567")
        #expect(ContentDetector.phoneNumber(in: "0532 123 45 67") == "05321234567")
        #expect(ContentDetector.phoneNumber(in: "05321234567") == "05321234567")
        #expect(ContentDetector.phoneNumber(in: "(212) 555-0123") == "2125550123")
        #expect(ContentDetector.phoneNumber(in: "+44 20 7946 0958") == "+442079460958")
        for text in ["123456", "482913", "2026-11-25", "25.11.2026", "12345678", "Order 4829133", "v1.2.3",
                     "1234 5678", "3.14159", "10:30-11:45", "999999999999999999"] {
            #expect(ContentDetector.phoneNumber(in: text) == nil, "\(text)")
        }
    }

    @Test func ipAddresses() {
        for text in ["192.168.1.10", "10.0.0.0/8", "203.0.113.5:8080", "::1", "fe80::1%en0", "2001:db8::/32",
                     "[2001:db8::1]:443", "::ffff:192.168.0.1", "10.0.0.1, 10.0.0.2\n10.0.0.3", "0.0.0.0"] {
            #expect(ContentDetector.ipAddresses(in: text) != nil, "\(text)")
        }
        for text in ["1.2.3", "256.1.1.1", "01.2.3.4", "1.2.3.4.5", "10.0.0.1/33", "10.0.0.1:0", "12:30", "10:30:45",
                     "aa:bb:cc:dd:ee:ff", "::", "v1.2.3.4", "3.14159", "25.11.2026", "Server 10.0.0.1", "std::vector",
                     "10.0.0.1/8:80", "[::1]80"] {
            #expect(ContentDetector.ipAddresses(in: text) == nil, "\(text)")
        }
        func scope(_ text: String) -> IPAddress.Scope? { IPAddress(text)?.scope }
        #expect(scope("8.8.8.8") == .public)
        #expect(scope("192.168.1.1") == .private)
        #expect(scope("172.20.0.1") == .private)
        #expect(scope("172.32.0.1") == .public)
        #expect(scope("127.0.0.1") == .loopback)
        #expect(scope("169.254.10.1") == .linkLocal)
        #expect(scope("239.255.255.250") == .multicast)
        #expect(scope("::1") == .loopback)
        #expect(scope("fe80::1") == .linkLocal)
        #expect(scope("fd12:3456::1") == .private)
        #expect(scope("2606:4700::1111") == .public)
        #expect(scope("::ffff:10.0.0.1") == .private)
        #expect(IPAddress("2001:db8::1")?.version == .v6)
        // Addresses that look like phone numbers are addresses.
        #expect(ClipClassifier.textKind(of: "192.168.100.100") == .ip)
        #expect(ClipClassifier.textKind(of: "http://192.168.1.1") == .link)
    }

    @Test func code() {
        let samples = [
            "git status",
            "$ npm install",
            "brew install sqlcipher",
            "ls -la ~/Projects",
            "cd ~/Projects/clipboard && make test",
            "SELECT id, name FROM users WHERE active = 1",
            "select * from clip;",
            #"{"name": "Clipboard", "version": 1}"#,
            "[1, 2, 3]",
            "let total = items.reduce(0, +)",
            "func greet(name: String) -> String {\n    return \"Hello \\(name)\"\n}",
            "def greet(name):\n    print(f\"Hello {name}\")\n    return name",
            "const a = [1, 2];\nconsole.log(a);",
            "import SwiftUI\n\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}",
            "#include <stdio.h>\nint main(void) {\n    printf(\"hi\");\n    return 0;\n}",
            "cd ~/Projects\ngit pull\nnpm run dev",
            "<?xml version=\"1.0\"?>\n<note>\n  <to>Tove</to>\n  <from>Jani</from>\n</note>",
            "<div class=\"card\">\n  <p>Hello<br>\n</div>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>",
        ]
        for text in samples {
            #expect(ContentDetector.isCode(text), "\(text)")
        }
        let prose = [
            "Toplantı Perşembe 14:00'te başlıyor, gündem ekte.",
            "git buradan",
            "Let me know when you're free.\nFor example, tomorrow (Tue) works.",
            "let me know (asap)\nfor sure (thanks)",
            "Update the docs\nCreate tickets\nDelete old branch",
            "Select a venue from the list",
            "Toplantı notları (pazartesi)\nAli: rapor (hazır)\nAyşe: tasarım (devam)",
            "make sure to call mom",
            "open the door",
            "go home",
            "- süt\n- ekmek\n- yumurta",
            "1. Giriş\n2. Yöntem\n3. Sonuç",
            "Merhaba,\n\nEkteki dosyayı inceleyebilir misiniz?\n\nTeşekkürler,\nDeniz",
            "{not json at all",
            "[link](https://example.com)",
            "Fiyat: 120 TL (KDV dahil)",
            "Class starts at 9 (room 4)",
            "<3 seni seviyorum <3",
            "<Ali> merhaba",
        ]
        for text in prose {
            #expect(!ContentDetector.isCode(text), "\(text)")
        }
    }

    @Test func languageGuess() {
        #expect(ContentDetector.language(of: #"{"a": 1}"#) == "JSON")
        #expect(ContentDetector.language(of: "SELECT * FROM t") == "SQL")
        #expect(ContentDetector.language(of: "git status") == "Shell")
        #expect(ContentDetector.language(of: "def f(x):\n    print(x)\n    return x") == "Python")
        #expect(ContentDetector.language(of: "import SwiftUI\nstruct A: View {\n    let x = 1\n}") == "Swift")
        #expect(ContentDetector.language(of: "<?xml version=\"1.0\"?>\n<a><b/></a>") == "XML")
        #expect(ContentDetector.language(of: "<svg width=\"1\"><rect/></svg>") == "SVG")
        #expect(ContentDetector.language(of: "<div>\n  <p>Hi</p>\n</div>") == "HTML")
    }
}

/// Structured data in Text: each format is recognised, and look-alike text is not.
struct DataFormatTests {
    typealias Format = ContentDetector.DataFormat

    @Test func recognisesFormats() {
        let cases: [(String, Format)] = [
            (#"{"name":"Clipboard","tags":["a","b"],"nested":{"x":1}}"#, .json),
            ("[{\"id\": 1}, {\"id\": 2}]", .json),
            ("{\"event\": \"open\"}\n{\"event\": \"copy\"}\n{\"event\": \"close\"}", .jsonLines),
            ("<?xml version=\"1.0\"?>\n<note>\n  <to>Tove</to>\n</note>", .xml),
            ("<catalog><book id=\"1\"><title>Swift</title></book></catalog>", .xml),
            ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>a</key><true/></dict></plist>", .plist),
            ("apiVersion: v1\nkind: Pod\nmetadata:\n  name: web\n  labels:\n    app: web", .yaml),
            ("---\nname: build\non: push\njobs: none", .yaml),
            ("[package]\nname = \"clipboard\"\nversion = \"0.1.0\"\n\n[dependencies]\ngrdb = \"7.12\"", .toml),
            ("[server]\nhost=localhost\nport=8080", .ini),
            ("DATABASE_URL=postgres://localhost/db\nDEBUG=true\nPORT=3000", .env),
            ("name,age,city\nAli,34,İstanbul\nAyşe,29,Ankara", .csv),
            ("Ad;Soyad;Puan\nAli;Yılmaz;90\nAyşe;Kaya;85", .csv),
            ("Ürün\tAdet\tFiyat\nKalem\t3\t12,50\nDefter\t1\t40,00", .tsv),
            ("Ocak\t1200\t1350", .tsv),
        ]
        for (text, format) in cases {
            #expect(ContentDetector.dataFormat(of: text) == format, "\(text)")
            #expect(ClipClassifier.textKind(of: text) == .data, "\(text)")
        }
    }

    @Test func leavesLookAlikesAlone() {
        let texts = [
            "Ali, Ayşe ve Mehmet geldi.\nToplantı uzun, verimli geçti.",
            "Merhaba, nasılsın?",
            "Ali: rapor hazır\nAyşe: tasarım devam ediyor\nMehmet: test",
            "Gündem:\n  - Bütçe\n  - Tasarım",
            "Agenda:\n- Budget\n- Design",
            "Not: yarın 10:00",
            "[link](https://example.com)",
            "<div><p>Hello</p></div>",
            "x = 5",
            "Price: 12,50 TL",
            "# Başlık\n\nBir paragraf.",
        ]
        for text in texts {
            #expect(ContentDetector.dataFormat(of: text) == nil, "\(text)")
        }
        // HTML stays code, not data.
        #expect(ClipClassifier.textKind(of: "<div><p>Hello</p></div>") == .code)
    }

    @Test func otherCodeFormats() {
        #expect(ContentDetector.isCode("diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b"))
        #expect(ContentDetector.isCode("FROM swift:6.0\nWORKDIR /app\nCOPY . .\nRUN swift build"))
        #expect(ContentDetector.isCode("query GetUser {\n  user(id: 1) {\n    name\n  }\n}"))
        #expect(ContentDetector.language(of: "FROM node:20\nRUN npm ci") == "Dockerfile")
        #expect(ContentDetector.isMarkdown("# Notes\n\n- one\n- **two**\n\nSee [docs](https://x.y)"))
        #expect(!ContentDetector.isMarkdown("Merhaba\nNasılsın?"))
    }

    @Test func prettyJSONKeepsOrderAndStrings() throws {
        let minified = #"{"z":1,"a":{"text":"a, b {c}: \"d\"","list":[1,2,{}],"empty":[]},"m":null}"#
        let pretty = try #require(Formatting.prettyJSON(minified))
        #expect(pretty == """
            {
              "z": 1,
              "a": {
                "text": "a, b {c}: \\"d\\"",
                "list": [
                  1,
                  2,
                  {}
                ],
                "empty": []
              },
              "m": null
            }
            """)
        // Same data after formatting.
        let original = try JSONSerialization.jsonObject(with: Data(minified.utf8)) as? NSDictionary
        let formatted = try JSONSerialization.jsonObject(with: Data(pretty.utf8)) as? NSDictionary
        #expect(original == formatted)
        #expect(Formatting.prettyJSON("not json") == nil)
    }

    @Test func prettyXMLAndTables() throws {
        let pretty = try #require(Formatting.prettyXML("<a><b x=\"1\">t</b><!-- note --><c/></a>"))
        #expect(pretty.contains("\n"))
        #expect(pretty.contains("<!-- note -->"))
        let rows = Formatting.table("name,quote\nAli,\"Merhaba, dünya\"\nAyşe,\"He said \"\"hi\"\"\"", separator: ",")
        #expect(rows == [["name", "quote"], ["Ali", "Merhaba, dünya"], ["Ayşe", "He said \"hi\""]])
    }
}

/// Every translatable text in the sources has a Turkish translation with the same placeholders.
/// Collects the literals of SwiftUI texts, `String(localized:)` and `L(…)`, as Xcode's string
/// extraction would (it needs Xcode; this runs with the Command Line Tools).
struct LocalizationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The text of a Swift string literal: escapes resolved, interpolations as %@.
    static func key(fromLiteral body: String) -> String {
        var out = ""
        var index = body.startIndex
        while index < body.endIndex {
            let c = body[index]
            if c == "\\" {
                let next = body.index(after: index)
                guard next < body.endIndex else { break }
                switch body[next] {
                case "(":
                    // Skip the balanced interpolation.
                    var depth = 0
                    var j = next
                    repeat {
                        if body[j] == "(" { depth += 1 } else if body[j] == ")" { depth -= 1 }
                        j = body.index(after: j)
                    } while depth > 0 && j < body.endIndex
                    out += "%@"
                    index = j
                    continue
                case "n": out += "\n"
                case "t": out += "\t"
                case "\"": out += "\""
                case "\\": out += "\\"
                case "\n": break // Line continuation in a multi-line literal.
                default: out.append(body[next])
                }
                index = body.index(after: next)
                continue
            }
            out.append(c)
            index = body.index(after: index)
        }
        return out
    }

    static func extractKeys() throws -> Set<String> {
        let opener = #"(?:\b(?:Text|Button|Toggle|Label|Picker|TextField|SecureField|Section|SettingNote|switchRow)\(|\.help\(|\.confirmationDialog\(|\b(?:label|title|message|detail):|String\(localized:|\bL\()\s*"#
        let single = try NSRegularExpression(pattern: opener + #""((?:[^"\\\n]|\\.)*)""#)
        let multi = try NSRegularExpression(pattern: opener + #"\"\"\"\n([\s\S]*?)\n([ \t]*)\"\"\""#)
        // Text(flag ? "One" : "Other"): both branches are shown, so both need a translation.
        let literal = #""((?:[^"\\\n]|\\.)*)""#
        let ternary = try NSRegularExpression(pattern: opener + #"[^"\n()?]*\?\s*"# + literal + #"\s*:\s*"# + literal)
        var keys = Set<String>()
        let sources = root.appendingPathComponent("Sources/Trove")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/Debug/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in single.matches(in: text, range: range) {
                keys.insert(key(fromLiteral: String(text[Range(match.range(at: 1), in: text)!])))
            }
            for match in ternary.matches(in: text, range: range) {
                for group in 1...2 { keys.insert(key(fromLiteral: String(text[Range(match.range(at: group), in: text)!]))) }
            }
            for match in multi.matches(in: text, range: range) {
                let indent = String(text[Range(match.range(at: 2), in: text)!])
                let lines = text[Range(match.range(at: 1), in: text)!].split(separator: "\n", omittingEmptySubsequences: false)
                let body = lines.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : String($0) }.joined(separator: "\n")
                keys.insert(key(fromLiteral: body))
            }
        }
        return keys.filter { $0.contains(where: \.isLetter) && $0 != "%@" }
    }

    @Test func everyTextHasATurkishTranslation() throws {
        let keys = try Self.extractKeys()
        #expect(keys.count > 200)
        let url = Self.root.appendingPathComponent("Resources/tr.lproj/Localizable.strings")
        let turkish = (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
        let missing = keys.filter { turkish[$0] == nil }.sorted()
        if !missing.isEmpty {
            print("MISSING-TR-BEGIN")
            for key in missing { print("MISSING-TR: " + key.replacingOccurrences(of: "\n", with: "\\n")) }
            print("MISSING-TR-END")
        }
        #expect(missing.isEmpty, "\(missing.count) texts have no Turkish translation")
        // Same number of placeholders; a translation may reorder them (%1$@, %2$@).
        let placeholder = try NSRegularExpression(pattern: #"%(\d+\$)?@"#)
        func count(_ text: String) -> Int { placeholder.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
        for (key, value) in turkish {
            #expect(count(key) == count(value), "Placeholders differ: \(key)")
        }
    }
}

/// Export and import: our formats round-trip, Maccy and Alfred databases are read.
@MainActor
struct TransferTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)")

    private func makeStore() throws -> Store {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Store.open(directory: directory.appendingPathComponent(UUID().uuidString), key: .random())
    }

    private func fill(_ store: Store) throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try store.ingest(ClipClassifier.textContent("Toplantı Perşembe, \"ekte\"\nikinci satır", rtf: nil),
                         source: ClipSource(bundleID: "ru.keepcoder.Telegram", appName: "Telegram", url: nil), at: date)
        let link = try store.ingest(ClipClassifier.textContent("https://github.com/groue/GRDB.swift", rtf: nil),
                                    source: ClipSource(appName: "Arc"), at: date.addingTimeInterval(60))
        try store.setPinned(id: try #require(link.id), true)
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data("pixels".utf8)
        try store.ingest(CapturedContent(kind: .image, imageData: png, imageWidth: 2, imageHeight: 2, byteSize: png.count,
                                         hash: ClipClassifier.hash("image", png)), source: ClipSource(appName: "Preview"), at: date)
        let paths = "/Users/me/a.pdf\n/Users/me/b.pdf"
        try store.ingest(CapturedContent(kind: .file, text: paths, byteSize: 10, hash: ClipClassifier.hash("file", paths)),
                         source: ClipSource(appName: "Finder"), at: date)
        _ = try store.ingestSecret(sealed: Data([1, 2, 3]), finding: .init(reason: "GitHub token", masked: "ghp_…"), characters: 40,
                                   source: ClipSource(), at: date, expiresAt: nil)
    }

    private func records(_ items: [Transfer.Item]) -> [Store.ImportRecord] {
        items.compactMap { item in
            let content: CapturedContent?
            if let files = item.files {
                let paths = files.joined(separator: "\n")
                content = CapturedContent(kind: .file, text: paths, byteSize: paths.utf8.count, hash: ClipClassifier.hash("file", paths))
            } else if let image = item.image {
                content = CapturedContent(kind: .image, imageData: image, imageWidth: item.imageWidth, imageHeight: item.imageHeight,
                                          byteSize: image.count, hash: ClipClassifier.hash("image", image))
            } else {
                content = item.text.map { ClipClassifier.textContent($0, rtf: item.rtf) }
            }
            return content.map {
                Store.ImportRecord(content: $0, source: ClipSource(appName: item.sourceApp), firstCopiedAt: item.firstCopiedAt,
                                   lastCopiedAt: item.lastCopiedAt, timesCopied: item.timesCopied, pinned: item.pinned)
            }
        }
    }

    @Test func jsonRoundTripKeepsEverythingButHidden() throws {
        let source = try makeStore()
        try fill(source)
        let items = try source.exportItems(since: nil, pinnedOnly: false, includeImages: true)
        #expect(items.count == 4) // The hidden item stays behind.
        #expect(!items.contains { $0.kind == ClipKind.secret.rawValue })

        let file = directory.appendingPathComponent("export.json")
        try Transfer.json(items).write(to: file)
        #expect(try Transfer.detect(file) == .clipboardJSON)
        let read = try Transfer.read(file, password: nil)
        #expect(read == items)

        let target = try makeStore()
        let result = try target.importRecords(records(read))
        #expect(result.added == 4 && result.merged == 0)
        let counts = try target.counts()
        #expect(counts[.all] == 4 && counts[.pinned] == 1 && counts[.images] == 1 && counts[.files] == 1)
        let image = try #require(try target.fetch(category: .images, query: "", limit: 1).first)
        #expect(target.imageData(for: image) == items.first { $0.image != nil }?.image)

        // A second import merges instead of duplicating.
        let again = try target.importRecords(records(read))
        #expect(again.added == 0 && again.merged == 4)
        #expect(try target.counts()[.all] == 4)
    }

    @Test func encryptedExportNeedsItsPassword() throws {
        let store = try makeStore()
        try fill(store)
        let items = try store.exportItems(since: nil, pinnedOnly: false, includeImages: true)
        let data = try Transfer.encrypted(items, password: "correct horse battery", iterations: 1_000)
        #expect(data.range(of: Data("Toplantı".utf8)) == nil)
        #expect(data.range(of: Data("github".utf8)) == nil)
        let file = directory.appendingPathComponent("export.clipboardexport")
        try data.write(to: file)
        #expect(try Transfer.detect(file) == .clipboardEncrypted)
        #expect(throws: Transfer.TransferError.needsPassword) { try Transfer.read(file, password: nil) }
        #expect(throws: Transfer.TransferError.wrongPassword) { try Transfer.read(file, password: "wrong password") }
        #expect(try Transfer.read(file, password: "correct horse battery") == items)
        #expect(throws: VaultError.passwordTooShort) { try Transfer.encrypted(items, password: "short") }
    }

    @Test func filtersAndCSV() throws {
        let store = try makeStore()
        try fill(store)
        #expect(try store.exportItems(since: nil, pinnedOnly: true, includeImages: true).count == 1)
        #expect(try store.exportItems(since: nil, pinnedOnly: false, includeImages: false).count == 3)
        #expect(try store.exportItems(since: Date(), pinnedOnly: false, includeImages: true).isEmpty)
        let csv = String(decoding: Transfer.csv(try store.exportItems(since: nil, pinnedOnly: false, includeImages: true)), as: UTF8.self)
        #expect(csv.hasPrefix("kind,text,source,first_copied,last_copied,times_copied,pinned\r\n"))
        #expect(csv.contains("\"Toplantı Perşembe, \"\"ekte\"\"\nikinci satır\""))
        #expect(!csv.contains("pixels"))
    }

    @Test func readsMaccy() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Storage.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZHISTORYITEM (Z_PK INTEGER PRIMARY KEY, ZAPPLICATION VARCHAR, ZFIRSTCOPIEDAT TIMESTAMP,
                    ZLASTCOPIEDAT TIMESTAMP, ZNUMBEROFCOPIES INTEGER, ZPIN VARCHAR, ZTITLE VARCHAR);
                CREATE TABLE ZHISTORYITEMCONTENT (Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZTYPE VARCHAR, ZVALUE BLOB);
                INSERT INTO ZHISTORYITEM VALUES (1, 'com.apple.Safari', 785000000, 785000100, 3, 'b', 'hello');
                INSERT INTO ZHISTORYITEM VALUES (2, 'com.apple.finder', 785000200, 785000200, 1, NULL, 'a.pdf');
                """)
            try db.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (1, 1, 'public.utf8-plain-text', ?)", arguments: [Data("hello from Maccy".utf8)])
            try db.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (2, 2, 'public.file-url', ?)", arguments: [Data("file:///Users/me/a.pdf".utf8)])
        }
        try queue.close()
        #expect(try Transfer.detect(url) == .maccy)
        let items = try Transfer.read(url, password: nil).sorted { $0.firstCopiedAt < $1.firstCopiedAt }
        #expect(items.count == 2)
        #expect(items[0].text == "hello from Maccy" && items[0].pinned && items[0].timesCopied == 3)
        #expect(items[0].sourceBundleID == "com.apple.Safari")
        #expect(items[0].lastCopiedAt == Date(timeIntervalSinceReferenceDate: 785000100))
        #expect(items[1].files == ["/Users/me/a.pdf"])
    }

    /// Maccy (SwiftData) writes in WAL mode: its newest rows can be only in Storage.sqlite-wal
    /// while it runs. The import reads a copy that includes the log.
    @Test func readsMaccyRowsStillInItsLog() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Storage.sqlite")
        let pool = try DatabasePool(path: url.path) // WAL mode, like Maccy.
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE ZHISTORYITEM (Z_PK INTEGER PRIMARY KEY, ZAPPLICATION VARCHAR, ZFIRSTCOPIEDAT TIMESTAMP,
                    ZLASTCOPIEDAT TIMESTAMP, ZNUMBEROFCOPIES INTEGER, ZPIN VARCHAR, ZTITLE VARCHAR);
                CREATE TABLE ZHISTORYITEMCONTENT (Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZTYPE VARCHAR, ZVALUE BLOB);
                """)
        }
        try pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) } // The tables are in the main file…
        try pool.write { db in // …the row only in the log, as long as the pool stays open.
            try db.execute(sql: "INSERT INTO ZHISTORYITEM VALUES (1, 'com.apple.Safari', 785000000, 785000100, 1, NULL, 'new')")
            try db.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (1, 1, 'public.utf8-plain-text', ?)", arguments: [Data("just copied".utf8)])
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let items = try Transfer.read(url, password: nil)
        Transfer.removeCopies()
        #expect(items.map(\.text) == ["just copied"])
        #expect(items.first?.sourceApp == "Safari") // The name of the installed app.
        try pool.close()
    }

    @Test func readsAlfred() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("clipboard.alfdb")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE clipboard (item TEXT, ts DECIMAL, app TEXT, apppath TEXT, dataType INTEGER, dataHash TEXT);
                INSERT INTO clipboard VALUES ('hello from Alfred', 785000000, 'Notes', '/System/Applications/Notes.app', 0, 'h1');
                INSERT INTO clipboard VALUES ('/Users/me/a.pdf', 785000050, 'Finder', '/System/Library/CoreServices/Finder.app', 2, 'h2');
                INSERT INTO clipboard VALUES ('image.tiff', 785000060, 'Preview', '', 1, 'h3');
                """)
        }
        try queue.close()
        #expect(try Transfer.detect(url) == .alfred)
        let items = try Transfer.read(url, password: nil)
        #expect(items.count == 2) // Images are not imported.
        #expect(items.contains { $0.text == "hello from Alfred" && $0.sourceApp == "Notes" })
        #expect(items.contains { $0.files == ["/Users/me/a.pdf"] })
    }

    @Test func rejectsOtherFiles() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("notes.txt")
        try Data("just some text".utf8).write(to: url)
        #expect(throws: Transfer.TransferError.unknownFile) { try Transfer.detect(url) }
    }
}

/// Detection of secrets: what must be caught and what must not.
struct SensitiveDetectorTests {
    @Test func catchesTokens() {
        let cases: [(String, String)] = [
            ("sk-ant-api03-" + String(repeating: "aB3_", count: 10), "Anthropic API key"),
            ("sk-proj-" + String(repeating: "Zx9", count: 12), "OpenAI API key"),
            ("ghp_" + String(repeating: "a1B2", count: 9), "GitHub token"),
            ("github_pat_" + String(repeating: "A1b2_", count: 10), "GitHub token"),
            ("AKIAIOSFODNN7EXAMPLE", "AWS access key"),
            ("xoxb-1234567890-abcdefghij", "Slack token"),
            ("AIza" + String(repeating: "S", count: 35), "Google API key"),
            ("sk_live_" + String(repeating: "4eC39HqLyjWDarjtT1zdp7dc", count: 1), "Stripe key"),
            ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "JSON Web Token"),
            ("OPENAI_API_KEY=sk-" + String(repeating: "q", count: 40), "OpenAI API key"),
            ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n-----END OPENSSH PRIVATE KEY-----", "Private key"),
            ("4242 4242 4242 4242", "Payment card"),
            ("9792-0300-0000-0000", "Payment card"), // Troy prefix, valid Luhn
            ("TR33 0006 1005 1978 6457 8413 26", "IBAN"),
            ("GB82WEST12345698765432", "IBAN"),
        ]
        for (text, reason) in cases {
            #expect(SensitiveDetector.detect(text)?.reason == reason, "\(text)")
        }
    }

    @Test func masksWithoutRevealing() throws {
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let finding = try #require(SensitiveDetector.detect(token))
        #expect(finding.masked == "ghp_…a1B2")
        #expect(SensitiveDetector.detect("4242 4242 4242 4242")?.masked == "•••• 4242")
        #expect(SensitiveDetector.detect("TR33 0006 1005 1978 6457 8413 26")?.masked == "TR•• •••• 1326")
    }

    @Test func ignoresOrdinaryText() {
        for text in [
            "Toplantı Perşembe 14:00'te başlıyor",
            "https://github.com/groue/GRDB.swift",
            "4242 4242 4242 4241",              // Luhn fails
            "1234 5678 9012 3456",              // no card prefix
            "My card is 4242 4242 4242 4242",   // cards only as the whole text
            "TR33 0006 1005 1978 6457 8413 27", // IBAN checksum fails
            "task-list-item and sk-short",
            "deploy notes 8 " + String(repeating: "x", count: 50),
            "#D97757",
        ] {
            #expect(SensitiveDetector.detect(text) == nil, "\(text)")
        }
    }
}

/// Hidden items: sealed to the hidden key, kept out of every other group and search.
@MainActor
struct HiddenItemTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-\(UUID().uuidString)")
    private let hiddenKey = SoftwareHiddenKey()
    private let token = "ghp_" + String(repeating: "Q7w", count: 12)

    private func addSecret(_ store: Store, at date: Date = Date(), expiresAt: Date? = nil) throws -> Clip {
        let finding = try #require(SensitiveDetector.detect(token))
        return try store.ingestSecret(sealed: try SealedSecret.seal(Data(token.utf8), to: hiddenKey.publicKey),
                                      finding: finding, characters: token.count,
                                      source: ClipSource(bundleID: "com.microsoft.VSCode", appName: "Code", url: nil),
                                      at: date, expiresAt: expiresAt)
    }

    @Test func sealedFormatOpensOnlyWithItsKey() throws {
        let sealed = try SealedSecret.seal(Data(token.utf8), to: hiddenKey.publicKey)
        #expect(sealed.prefix(4) == Data("CLPS".utf8))
        #expect(sealed.range(of: Data(token.utf8)) == nil)
        #expect(try SealedSecret.open(sealed, with: hiddenKey, context: nil) == Data(token.utf8))
        #expect(throws: (any Error).self) { try SealedSecret.open(sealed, with: SoftwareHiddenKey(), context: nil) }
    }

    @Test func staysInHiddenOnly() throws {
        let store = try Store.open(directory: directory, key: .random())
        try store.ingest(ClipClassifier.textContent("normal text about Code", rtf: nil), source: ClipSource(), at: Date())
        let secret = try addSecret(store)

        #expect(try store.fetch(category: .all, query: "", limit: 10).map(\.kind) == [.text])
        #expect(try store.fetch(category: .text, query: "", limit: 10).count == 1)
        #expect(try store.fetch(category: .pinned, query: "", limit: 10).isEmpty)
        #expect(try store.fetch(category: .all, query: "github", limit: 10).isEmpty)
        #expect(try store.fetch(category: .all, query: "Q7w", limit: 10).isEmpty)

        let hidden = try store.fetch(category: .hidden, query: "", limit: 10)
        #expect(hidden.count == 1)
        #expect(hidden.first?.title == "ghp_…" + token.suffix(4))
        #expect(hidden.first?.secretReason == "GitHub token")
        #expect(hidden.first?.sealed == nil) // Lists never load the sealed content.
        #expect(try store.fetch(category: .hidden, query: "github", limit: 10).count == 1)
        #expect(try store.fetch(category: .hidden, query: "Q7wQ7w", limit: 10).isEmpty) // Not by content.

        let counts = try store.counts()
        #expect(counts[.all] == 1)
        #expect(counts[.hidden] == 1)

        let secretID = try #require(secret.id)
        let full = try #require(try store.clip(id: secretID))
        let sealed = try #require(full.sealed)
        let opened = try SealedSecret.open(sealed, with: hiddenKey, context: nil)
        #expect(opened == Data(token.utf8))
        try store.close()

        let database = try Data(contentsOf: directory.appendingPathComponent(Store.databaseFileName))
        #expect(database.range(of: Data(token.utf8)) == nil)
        #expect(database.range(of: Data("GitHub token".utf8)) == nil)
    }

    @Test func hidingOnPurposeRemovesThePlainText() throws {
        let store = try Store.open(directory: directory, key: .random())
        let password = "Kedi-Mavi-1987!"
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        let saved = try store.ingest(ClipClassifier.textContent(password, rtf: nil), source: ClipSource(appName: "Notes"), at: first)
        let id = try #require(saved.id)
        #expect(try store.fetch(category: .all, query: "Kedi", limit: 10).count == 1)

        try store.hide(id: id, sealed: try SealedSecret.seal(Data(password.utf8), to: hiddenKey.publicKey),
                       characters: password.count, name: "Banka şifresi")
        #expect(try store.fetch(category: .all, query: "", limit: 10).isEmpty)
        #expect(try store.fetch(category: .all, query: "Kedi", limit: 10).isEmpty)
        #expect(try store.fetch(category: .hidden, query: "Kedi", limit: 10).isEmpty) // Never by content.
        let listed = try #require(try store.fetch(category: .hidden, query: "Banka", limit: 10).first)
        #expect(listed.title == "Banka şifresi")
        #expect(listed.secretReason == Store.manualReason)
        let full = try #require(try store.clip(id: id))
        #expect(full.text == Store.fullMask && full.rtf == nil && full.textCharacters == password.count)
        let sealed = try #require(full.sealed)
        #expect(try SealedSecret.open(sealed, with: hiddenKey, context: nil) == Data(password.utf8))

        try store.renameSecret(id: id, name: "İş hesabı")
        #expect(try store.fetch(category: .hidden, query: "Banka", limit: 10).isEmpty)
        #expect(try store.fetch(category: .hidden, query: "hesab", limit: 10).first?.title == "İş hesabı")
        try store.renameSecret(id: id, name: "  ")
        #expect(try store.clip(id: id)?.title == Store.fullMask)
        try store.close()

        let database = try Data(contentsOf: directory.appendingPathComponent(Store.databaseFileName))
        #expect(database.range(of: Data(password.utf8)) == nil)
    }

    @Test func copyingAHiddenTextAgainKeepsItHidden() throws {
        let store = try Store.inMemory(imagesDirectory: directory.appendingPathComponent("Images"))
        let password = "hunter2"
        let saved = try store.ingest(ClipClassifier.textContent(password, rtf: nil), source: ClipSource(), at: Date(timeIntervalSince1970: 1_790_000_000))
        let id = try #require(saved.id)
        try store.hide(id: id, sealed: Data([1]), characters: password.count, name: nil)
        let later = Date(timeIntervalSince1970: 1_790_100_000)
        let again = try store.ingest(ClipClassifier.textContent(password, rtf: nil), source: ClipSource(), at: later)
        #expect(again.id == id && again.kind == .secret && again.timesCopied == 2 && again.lastCopiedAt == later)
        #expect(try store.counts()[.all] == 0)
        // An import of the same text merges into the hidden item too.
        let record = Store.ImportRecord(content: ClipClassifier.textContent(password, rtf: nil), source: ClipSource(),
                                        firstCopiedAt: later, lastCopiedAt: later, timesCopied: 5, pinned: false)
        #expect(try store.importRecords([record]).merged == 1)
        #expect(try store.counts()[.all] == 0 && store.counts()[.hidden] == 1)
        // Moved back, it is a normal item again, and a new copy merges with it.
        try store.unhide(id: id, content: ClipClassifier.textContent(password, rtf: nil))
        #expect(try store.counts()[.all] == 1 && store.counts()[.hidden] == 0)
    }

    @Test func movingBackRestoresTheItem() throws {
        let store = try Store.inMemory(imagesDirectory: directory.appendingPathComponent("Images"))
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        let saved = try store.ingest(ClipClassifier.textContent("ali@example.com", rtf: nil), source: ClipSource(appName: "Mail"), at: first)
        let id = try #require(saved.id)
        try store.hide(id: id, sealed: Data([1]), characters: 15, name: nil)
        #expect(try store.counts()[.emails] == 0 && store.counts()[.hidden] == 1)
        try store.unhide(id: id, content: ClipClassifier.textContent("ali@example.com", rtf: nil))
        let counts = try store.counts()
        #expect(counts[.emails] == 1 && counts[.hidden] == 0)
        let back = try #require(try store.fetch(category: .emails, query: "", limit: 1).first)
        #expect(back.firstCopiedAt == first && back.sourceAppName == "Mail")
    }

    @Test func oneMinuteItemsDeleteThemselves() throws {
        let store = try Store.inMemory(imagesDirectory: directory.appendingPathComponent("Images"))
        let now = Date()
        _ = try addSecret(store, at: now, expiresAt: now.addingTimeInterval(60))
        _ = try addSecret(store, at: now)
        #expect(try store.nextExpiry().map { abs($0.timeIntervalSince(now) - 60) < 1 } == true)
        let keepAll = PruneLimits(retentionDays: 0, maxItems: 0, maxBytes: 0)
        #expect(try store.prune(keepAll, now: now.addingTimeInterval(30)) == 0)
        #expect(try store.prune(keepAll, now: now.addingTimeInterval(61)) == 1)
        #expect(try store.counts()[.hidden] == 1)
        #expect(try store.nextExpiry() == nil)
    }
}

/// Encryption at rest, keys and the recovery password.
@MainActor
struct EncryptionTests {
    private let marker = "SECRET-marker-7f3a telefon şifresi"
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("encryption-\(UUID().uuidString)")
    private let keyStore = MemoryKeyStore()
    private var vault: Vault { Vault(keyStore: keyStore, iterations: 1_000) }

    private func readyKey() throws -> DataKey {
        guard case .ready(let key) = try vault.prepare(directory: directory) else {
            throw CocoaError(.featureUnsupported)
        }
        return key
    }

    /// Fills a store with text, a link and an image, then closes it.
    private func fill(with key: DataKey) throws {
        let store = try Store.open(directory: directory, key: key)
        let source = ClipSource(bundleID: "ru.keepcoder.Telegram", appName: "Telegram", url: "https://secret.example/page")
        try store.ingest(ClipClassifier.textContent(marker, rtf: nil), source: source, at: Date())
        try store.ingest(ClipClassifier.textContent("https://secret.example/token", rtf: nil), source: source, at: Date())
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(marker.utf8)
        try store.ingest(CapturedContent(kind: .image, imageData: png, imageWidth: 1, imageHeight: 1, byteSize: png.count,
                                         hash: ClipClassifier.hash("image", png)), source: source, at: Date())
        try store.close()
    }

    @Test func filesHoldNoPlaintext() throws {
        try fill(with: try readyKey())
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            let data = try Data(contentsOf: url)
            for needle in [marker, "secret.example", "Telegram", "SQLite format 3"] {
                #expect(data.range(of: Data(needle.utf8)) == nil, "\(url.lastPathComponent) contains \(needle)")
            }
            #expect(data.range(of: Data([0x89, 0x50, 0x4E, 0x47])) == nil, "\(url.lastPathComponent) contains a PNG header")
            checked += 1
        }
        #expect(checked >= 3) // database, key file, image
    }

    @Test func wrongKeyCannotOpen() throws {
        try fill(with: try readyKey())
        #expect(throws: (any Error).self) { try Store.open(directory: directory, key: .random()) }
        // The right key still works.
        let store = try Store.open(directory: directory, key: try readyKey())
        #expect(try store.fetch(category: .all, query: "telefon", limit: 10).count == 1)
    }

    @Test func recoveryPasswordOpensOnNewMac() throws {
        let key = try readyKey()
        try fill(with: key)
        try vault.setRecoveryPassword("correct horse battery", key: key, directory: directory)
        #expect(vault.hasRecoveryPassword(directory: directory))
        let keyFile = try Data(contentsOf: KeyFile.url(in: directory))
        #expect(keyFile.range(of: key.raw) == nil)
        #expect(keyFile.range(of: Data(key.raw.base64EncodedString().utf8)) == nil)

        keyStore.clear() // A new Mac: same folder, empty Keychain.
        guard case .locked(let file) = try vault.prepare(directory: directory) else {
            Issue.record("Expected a locked history")
            return
        }
        #expect(throws: VaultError.wrongPassword) { try vault.unlock(file, password: "wrong password") }
        #expect(throws: VaultError.wrongPassword) { try vault.unlock(file, password: "") }
        let unlocked = try vault.unlock(file, password: "correct horse battery")
        #expect(unlocked.raw == key.raw)

        // The key is now in this Mac's Keychain: the next start needs no password.
        guard case .ready = try vault.prepare(directory: directory) else {
            Issue.record("Expected the key in the Keychain after unlocking")
            return
        }
        let store = try Store.open(directory: directory, key: unlocked)
        let clips = try store.fetch(category: .all, query: "", limit: 10)
        #expect(clips.count == 3)
        let image = try #require(clips.first { $0.kind == .image })
        #expect(store.imageData(for: image).map { $0.suffix(marker.utf8.count) } == Data(marker.utf8))
    }

    @Test func changingAndRemovingThePassword() throws {
        let key = try readyKey()
        try fill(with: key)
        #expect(throws: VaultError.passwordTooShort) { try vault.setRecoveryPassword("short", key: key, directory: directory) }
        try vault.setRecoveryPassword("first password", key: key, directory: directory)
        try vault.setRecoveryPassword("second password", key: key, directory: directory)
        keyStore.clear()
        guard case .locked(let file) = try vault.prepare(directory: directory) else {
            Issue.record("Expected a locked history")
            return
        }
        #expect(throws: VaultError.wrongPassword) { try vault.unlock(file, password: "first password") }
        #expect(try vault.unlock(file, password: "second password").raw == key.raw)

        try vault.setRecoveryPassword(nil, key: key, directory: directory)
        #expect(!vault.hasRecoveryPassword(directory: directory))
    }

    @Test func withoutKeyOrPasswordTheHistoryIsUnrecoverable() throws {
        try fill(with: try readyKey())
        keyStore.clear()
        guard case .unrecoverable = try vault.prepare(directory: directory) else {
            Issue.record("Expected an unrecoverable history")
            return
        }
        // A missing key file is the same: a new key must never replace the lost one.
        try FileManager.default.removeItem(at: KeyFile.url(in: directory))
        guard case .unrecoverable = try vault.prepare(directory: directory) else {
            Issue.record("Expected an unrecoverable history without a key file")
            return
        }
    }

    @Test func newFolderGetsOneKey() throws {
        let first = try readyKey()
        let second = try readyKey()
        #expect(first.raw == second.raw)
        let file = try #require(try KeyFile.read(in: directory))
        #expect(try keyStore.load(storeID: file.storeID) == first.raw)
    }

    @Test func imageFileFormat() throws {
        let key = DataKey.random()
        let data = Data(marker.utf8)
        let sealed = try EncryptedFile.seal(data, with: key.imageKey)
        #expect(sealed.prefix(4) == Data("CLPE".utf8))
        #expect(try EncryptedFile.open(sealed, with: key.imageKey) == data)
        #expect(throws: (any Error).self) { try EncryptedFile.open(sealed, with: DataKey.random().imageKey) }
        var tampered = sealed
        tampered[tampered.count - 20] ^= 0x01
        #expect(throws: (any Error).self) { try EncryptedFile.open(tampered, with: key.imageKey) }
        // Two keys derived for different purposes are different.
        #expect(key.databasePassphrase.count == 67)
        #expect(key.imageKey.withUnsafeBytes { Data($0) } != key.raw)
    }
}

/// Runs `work` 5 times. The median is the steady-state cost; the maximum shows outliers
/// caused by other load on the machine.
@discardableResult
/// Nine runs: the median ignores a few slow ones caused by other work on the Mac.
func measure(_ work: () throws -> Void) rethrows -> (median: Duration, max: Duration) {
    var samples: [Duration] = []
    for _ in 0..<9 {
        let start = ContinuousClock.now
        try work()
        samples.append(ContinuousClock.now - start)
    }
    samples.sort()
    return (samples[4], samples[8])
}

/// Timings measured again when the first run misses the limit; the faster run counts. A busy
/// Mac (Spotlight indexing, a build) slows one whole run down; a real regression is slow twice.
func betterOfTwo(limit: Duration, _ run: () throws -> [(String, Duration)]) rethrows -> [(String, Duration)] {
    let first = try run()
    let firstWorst = first.map(\.1).max() ?? .zero
    guard firstWorst >= limit else { return first }
    let second = try run()
    return (second.map(\.1).max() ?? .zero) < firstWorst ? second : first
}

@MainActor
@Suite(.serialized)
struct GroupSelectionTests {
    private let app = AppModel()

    /// Five text items, newest first in the list: e, d, c, b, a.
    private func makeModel() throws -> (PanelModel, Store) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        let now = Date()
        for (index, text) in ["a", "b", "c", "d", "e"].enumerated() {
            try store.ingest(ClipClassifier.textContent("item \(text)", rtf: nil), source: ClipSource(),
                             at: now.addingTimeInterval(Double(index - 10)))
        }
        app.panelModel.willShow()
        return (app.panelModel, store)
    }

    private func titles(_ clips: [Clip]) -> [String] { clips.map(\.title) }

    @Test func commandClickPicksAndShiftClickPicksARange() throws {
        let (model, _) = try makeModel()
        #expect(!model.selecting && titles(model.actionClips) == ["item e"])

        #expect(model.click(model.clips[2], modifiers: .command))
        #expect(model.selecting)
        #expect(titles(model.pickedClips) == ["item e", "item c"]) // The selected item joins.

        #expect(model.click(model.clips[4], modifiers: .shift)) // From c to a.
        #expect(titles(model.pickedClips) == ["item c", "item b", "item a"])
        #expect(titles(model.actionClips) == ["item c", "item b", "item a"])

        #expect(!model.click(model.clips[0], modifiers: []))
    }

    @Test func plainClickTogglesInSelectMode() throws {
        let (model, _) = try makeModel()
        model.toggleSelecting()
        #expect(model.picked.count == 1)
        model.select(model.clips[1])
        model.select(model.clips[3])
        #expect(titles(model.pickedClips) == ["item e", "item d", "item b"])
        model.select(model.clips[1])
        #expect(titles(model.pickedClips) == ["item e", "item b"])
    }

    @Test func shiftArrowsAndSelectAll() throws {
        let (model, _) = try makeModel()
        model.extendSelection(1)
        model.extendSelection(1)
        #expect(titles(model.pickedClips) == ["item e", "item d", "item c"])
        model.extendSelection(-1)
        #expect(titles(model.pickedClips) == ["item e", "item d"])
        model.pickAll()
        #expect(model.picked.count == 5)
    }

    @Test func escapeAndGroupChangeEndSelectMode() throws {
        let (model, _) = try makeModel()
        model.query = "item"
        model.pickAll()
        #expect(!model.escape()) // First Esc: stop selecting, keep the search and the panel.
        #expect(!model.selecting && model.picked.isEmpty && model.query == "item")

        model.pickAll()
        model.category = .links
        #expect(!model.selecting && model.picked.isEmpty)
    }

    @Test func searchKeepsOnlyVisiblePicks() throws {
        let (model, _) = try makeModel()
        model.pickAll()
        model.query = "item b"
        #expect(titles(model.pickedClips) == ["item b"])
        #expect(!model.hasGroupSelection)
    }

    @Test func dragBringsTheGroupOnlyFromAPickedRow() throws {
        let (model, _) = try makeModel()
        _ = model.click(model.clips[1], modifiers: .command)
        #expect(model.dragClips(from: model.clips[1]).count == 2)
        #expect(titles(model.dragClips(from: model.clips[3])) == ["item b"])
    }

    @Test func groupDeleteAsksFirstAndKeepsTheRest() throws {
        let (model, store) = try makeModel()
        _ = model.click(model.clips[1], modifiers: .command)
        _ = model.click(model.clips[2], modifiers: .command)
        model.requestDelete()
        #expect(model.pendingDelete?.count == 3)
        #expect(try store.counts()[.all] == 5) // Nothing deleted before ↵.
        model.confirmDelete()
        #expect(try store.counts()[.all] == 2)
        #expect(!model.selecting)
        #expect(model.selected?.title == "item b") // The nearest item that stayed.
    }

    @Test func hiddenItemsCannotBePicked() throws {
        let (model, store) = try makeModel()
        let key = SoftwareHiddenKey()
        let token = "ghp_" + String(repeating: "x7Kq", count: 9)
        let finding = try #require(SensitiveDetector.detect(token))
        let secret = try store.ingestSecret(sealed: try SealedSecret.seal(Data(token.utf8), to: key.publicKey), finding: finding,
                                            characters: token.count, source: ClipSource(), at: Date(), expiresAt: nil)
        model.togglePick(secret)
        #expect(!model.selecting)
        #expect(model.dragClips(from: secret).isEmpty)
        model.category = .hidden
        #expect(!model.canSelectSeveral)
    }
}

@MainActor
@Suite(.serialized)
struct GroupJumpTests {
    private let app = AppModel()

    private func makeModel() throws -> PanelModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        for text in ["ekran notu", "https://example.com", "/usr/bin/swift"] {
            try store.ingest(ClipClassifier.textContent(text, rtf: nil), source: ClipSource(), at: Date())
        }
        app.panelModel.willShow()
        return app.panelModel
    }

    @Test func slashListsGroupsWithoutSearching() throws {
        let model = try makeModel()
        model.query = "/"
        #expect(model.groupSuggestions == model.visibleGroups)
        #expect(model.searchQuery.isEmpty)
        #expect(model.clips.count == 3) // The list does not search for "/".
        model.query = "/ima"
        #expect(model.groupSuggestions.first == .images)
        model.query = "/img"
        #expect(model.groupSuggestions == [.images])
        model.query = "/li"
        #expect(model.groupSuggestions.contains(.links))
    }

    @Test func returnChoosesTheHighlightedGroup() throws {
        let model = try makeModel()
        model.query = "/l"
        let suggestions = model.groupSuggestions
        model.moveGroupPick(1)
        let expected = suggestions[min(1, suggestions.count - 1)]
        model.chooseGroupSuggestion()
        #expect(model.category == expected)
        #expect(model.query.isEmpty)
    }

    @Test func spaceChoosesTheGroupAndKeepsTheSearch() throws {
        let model = try makeModel()
        model.query = "/link example"
        #expect(model.category == .links)
        #expect(model.query == "example")
        #expect(model.clips.count == 1)
    }

    @Test func pathsAreStillSearched() throws {
        let model = try makeModel()
        model.query = "/usr/bin"
        #expect(model.groupFilter == nil)
        #expect(model.searchQuery == "/usr/bin")
        #expect(model.clips.count == 1)
    }

    @Test func backspaceInEmptySearchReturnsToAll() throws {
        let model = try makeModel()
        model.query = "/links "
        #expect(model.category == .links && model.query.isEmpty)
        #expect(model.clearGroup())
        #expect(model.category == .all)
        #expect(!model.clearGroup()) // Already in All: ⌫ does nothing.
    }

    @Test func namesIgnoreCaseAccentsAndTurkishI() {
        #expect(ClipCategory.fold("Görseller") == "gorseller")
        #expect(ClipCategory.fold("IŞIK İz") == "isik iz")
        #expect(ClipCategory.images.matches("FOTO"))
        #expect(ClipCategory.hidden.matches("sifre"))
        #expect(!ClipCategory.images.matches("usr"))
        #expect(!ClipCategory.images.matches("s")) // One letter: names only, no aliases.
        #expect(ClipCategory.screenshots.matches("sc"))
    }

    @Test func oneLetterKeepsTheListShort() throws {
        let model = try makeModel()
        model.query = "/c"
        #expect(model.groupSuggestions == [.code, .colors])
        model.query = "/te"
        #expect(model.groupSuggestions.first == .text) // A name match comes before an alias (tel).
    }
}

@MainActor
@Suite(.serialized)
struct ActionsMenuTests {
    private let app = AppModel()

    @Test func listsActionsForTheSelectionAndFilters() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        try store.ingest(ClipClassifier.textContent("https://example.com", rtf: nil), source: ClipSource(), at: Date())
        try store.ingest(ClipClassifier.textContent("hello", rtf: nil), source: ClipSource(), at: Date().addingTimeInterval(-5))
        let model = app.panelModel
        model.willShow()

        let ids = model.actions.map(\.id)
        #expect(ids.first == "paste")
        #expect(ids.contains("secondary")) // The link: Open in Browser.
        #expect(ids.contains("pin") && ids.contains("delete") && ids.last == "settings")

        model.toggleActions()
        #expect(model.actionsOpen)
        model.actionFilter = "PIN"
        #expect(model.filteredActions.map(\.id) == ["pin"])
        model.runPickedAction()
        #expect(!model.actionsOpen)
        #expect(model.selected?.pinned == true)

        model.toggleActions()
        model.actionFilter = "zzz"
        #expect(model.filteredActions.isEmpty)
        model.closeActions()

        model.pickAll()
        #expect(model.actions.map(\.id) == ["paste", "all", "done", "delete", "pause", "settings"])
    }
}

@MainActor
@Suite(.serialized)
struct ImageGroupTests {
    private func store() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
    }

    private func png() throws -> Data {
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        return try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
    }

    private func fileContent(_ paths: [String], preview: Data? = nil) -> CapturedContent {
        let text = paths.joined(separator: "\n")
        var content = CapturedContent(kind: .file, text: text, byteSize: text.utf8.count, hash: ClipClassifier.hash("file", text))
        if Clip.areImageFiles(paths) { content.format = Clip.imageFilesFormat }
        content.imageData = preview
        return content
    }

    @Test func imageFilesShowInImagesAndFiles() throws {
        let store = try store()
        try store.ingest(fileContent(["/tmp/a.png"], preview: try png()), source: ClipSource(), at: Date())
        try store.ingest(fileContent(["/tmp/report.pdf"]), source: ClipSource(), at: Date())
        let counts = try store.counts()
        #expect(counts[.images] == 1 && counts[.files] == 2 && counts[.screenshots] == 0)
        let images = try store.fetch(category: .images, query: "", limit: 10)
        #expect(images.map(\.isImageFiles) == [true]) // List rows know it too (icon).
        let id = try #require(images.first?.id)
        let full = try #require(try store.clip(id: id))
        #expect(store.imageData(for: full) != nil) // The preview is stored, encrypted.
    }

    @Test func screenshotsAreASubgroupOfImages() throws {
        let store = try store()
        var shot = try #require(ClipClassifier.imageContent(data: try png(), maxBytes: 1_000_000))
        shot.text = "/Users/me/Desktop/Screenshot 1.png"
        try store.ingest(shot, source: ClipSource(bundleID: Clip.screenshotSource, appName: "Screenshot", url: nil), at: Date())
        var copied = try #require(ClipClassifier.imageContent(data: try png(), maxBytes: 1_000_000))
        copied.hash = "other"
        try store.ingest(copied, source: ClipSource(bundleID: "com.figma.Desktop", appName: "Figma", url: nil), at: Date())
        let counts = try store.counts()
        #expect(counts[.images] == 2 && counts[.screenshots] == 1)
        #expect(try store.fetch(category: .screenshots, query: "", limit: 10).count == 1)
    }

    @Test func copyingAScreenshotFileMovesTheScreenshotUp() throws {
        let store = try store()
        let path = "/Users/me/Desktop/Screenshot 1.png"
        var shot = try #require(ClipClassifier.imageContent(data: try png(), maxBytes: 1_000_000))
        shot.text = path
        let first = try store.ingest(shot, source: ClipSource(bundleID: Clip.screenshotSource, appName: "Screenshot", url: nil),
                                     at: Date().addingTimeInterval(-60))
        let again = try store.ingest(fileContent([path]), source: ClipSource(bundleID: "com.apple.finder", appName: "Finder", url: nil), at: Date())
        #expect(again.id == first.id && again.timesCopied == 2)
        #expect(try store.counts()[.all] == 1) // No second item.
    }

    @Test func imageFileNames() {
        #expect(Clip.areImageFiles(["/a/b.PNG", "/a/c.jpeg", "/a/d.heic"]))
        #expect(!Clip.areImageFiles(["/a/b.png", "/a/notes.txt"]))
        #expect(!Clip.areImageFiles(["/a/folder"]))
    }

    @Test func previewOfAnImageFileIsSmall() throws {
        let big = NSImage(size: NSSize(width: 3000, height: 1000), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        let rep = try #require(big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try #require(ClipClassifier.imagePreview(of: url))
        #expect(preview.width == rep.pixelsWide && preview.height == rep.pixelsHigh) // The original size.
        let small = try #require(NSBitmapImageRep(data: preview.png))
        #expect(max(small.pixelsWide, small.pixelsHigh) <= 1600)
    }
}

struct ImageTextTests {
    /// A white image with black text, as a screenshot of a document would be.
    static func imageWithText(_ text: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 900, height: 200), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            (text as NSString).draw(at: NSPoint(x: 40, y: 80), withAttributes: [
                .font: NSFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor.black,
            ])
            return true
        }
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func visionReadsTextWithItsPlace() throws {
        let read = try #require(TextRecognizer.recognize(try Self.imageWithText("Fatura Şubat 2026 ödendi")))
        let line = try #require(read.lines.first)
        #expect(read.plainText.localizedCaseInsensitiveContains("fatura"))
        #expect(read.plainText.contains("2026"))
        // The text is drawn in the left part of the image, a little below the middle.
        #expect(line.x > 0 && line.x < 0.2 && line.w > 0.3 && line.y > 0.2 && line.y < 0.8)
        #expect(TextRecognizer.recognize(Data("not an image".utf8)) == nil)
    }

    private static func line(_ text: String, y: Double = 0) -> RecognizedText.Line {
        RecognizedText.Line(text: text, x: 0.1, y: y, w: 0.8, h: 0.1)
    }

    @Test func matchesIgnoreCaseAccentsAndTurkishLetters() {
        let text = RecognizedText(lines: [Self.line("Customer: Ayse Yilmaz"), Self.line("Status: paid", y: 0.5)])
        // Vision reads Turkish without its letters; a search with them still matches.
        #expect(text.lines(matching: ["Yılmaz"]).map(\.text) == ["Customer: Ayse Yilmaz"])
        #expect(text.lines(matching: ["PAID"]).map(\.text) == ["Status: paid"])
        #expect(text.lines(matching: ["fatura"]).isEmpty)
        let box = try? #require(text.highlights(for: ["paid"]).first)
        #expect(box.map { $0.minX > 0.5 && $0.maxX <= 0.9 + 0.0001 && $0.minY == 0.5 } == true) // The end of the line.
        #expect(RecognizedText.snippet(of: "Status: paid\nDue: 30 November", terms: ["due"]) == "Status: paid · Due: 30 November")
    }

    @Test @MainActor func searchFindsImagesByTheirText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        let content = try #require(ClipClassifier.imageContent(data: try Self.imageWithText("x"), maxBytes: 10_000_000))
        let clip = try store.ingest(content, source: ClipSource(), at: Date())
        let id = try #require(clip.id)

        #expect(try store.imagesAwaitingRecognition(limit: 10).map(\.id) == [id])
        #expect(try store.recognitionProgress() == (done: 0, total: 1))
        try store.setRecognizedText(id: id, RecognizedText(lines: [Self.line("Kargo takip numarasi 4815"), Self.line("Alici: Deniz Yilmaz", y: 0.4)]))
        #expect(try store.imagesAwaitingRecognition(limit: 10).isEmpty)
        #expect(try store.recognitionProgress() == (done: 1, total: 1))

        #expect(try store.fetch(category: .images, query: "kargo", limit: 10).map(\.id) == [id]) // Trigram index.
        #expect(try store.fetch(category: .all, query: "numarası", limit: 10).map(\.id) == [id]) // Turkish letters typed.
        #expect(try store.fetch(category: .all, query: "Deniz", limit: 10).map(\.id) == [id])
        #expect(try store.fetch(category: .all, query: "48", limit: 10).map(\.id) == [id])      // Short terms: LIKE.
        #expect(try store.fetch(category: .all, query: "fatura", limit: 10).isEmpty)
        #expect(try store.recognizedTexts(ids: [id])[id]?.hasPrefix("Kargo") == true)
        // The list does not load it; the detail does, with each line's place.
        #expect(try store.fetch(category: .images, query: "", limit: 10).first?.recognizedText == nil)
        let full = try #require(try store.clip(id: id))
        #expect(RecognizedText.load(layout: full.recognizedLayout, text: full.recognizedText)?.lines.count == 2)

        // An image Vision cannot read is marked, so it is not read again.
        try store.setRecognizedText(id: id, nil)
        #expect(try store.imagesAwaitingRecognition(limit: 10).isEmpty)

        try store.clearRecognizedText()
        #expect(try store.fetch(category: .all, query: "kargo", limit: 10).isEmpty)
        #expect(try store.recognitionProgress() == (done: 0, total: 1))
    }
}

struct TextTransformTests {
    private let turkish = Locale(identifier: "tr_TR")

    @Test func caseFollowsTheLanguage() {
        #expect(TextTransform.uppercase.apply("istanbul ılık", locale: turkish) == "İSTANBUL ILIK")
        #expect(TextTransform.lowercase.apply("İSTANBUL", locale: turkish) == "istanbul")
        #expect(TextTransform.sentenceCase.apply("merhaba DÜNYA. nasılsın?", locale: turkish) == "Merhaba dünya. Nasılsın?")
    }

    @Test func linesAndSpaces() {
        #expect(TextTransform.trimLines.apply("  a  \n b \n") == "a\nb")
        #expect(TextTransform.collapseSpaces.apply("a    b\t\tc") == "a b c")
        #expect(TextTransform.removeEmptyLines.apply("a\n\n  \nb") == "a\nb")
        #expect(TextTransform.sortLines.apply("item10\nitem2\nb") == "b\nitem2\nitem10")
        #expect(TextTransform.removeDuplicateLines.apply("a\nb\na") == "a\nb")
        #expect(TextTransform.reverseLines.apply("1\n2\n3") == "3\n2\n1")
    }

    @Test func encodings() {
        #expect(TextTransform.urlEncode.apply("a b&ç") == "a%20b%26%C3%A7")
        #expect(TextTransform.urlDecode.apply("a%20b%26%C3%A7") == "a b&ç")
        #expect(TextTransform.base64Encode.apply("Trove ✓") == "VHJvdmUg4pyT")
        #expect(TextTransform.base64Decode.apply("VHJvdmUg4pyT") == "Trove ✓")
        #expect(TextTransform.base64Decode.apply("not base64!") == nil)
        #expect(TextTransform.jsonMinify.apply("{ \"a\" : [1, 2] }") == #"{"a":[1,2]}"#)
        #expect(TextTransform.jsonPretty.apply("not json") == nil)
    }

    @Test @MainActor func editorPastesTheResultAndKeepsTheOriginal() throws {
        let app = AppModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        try store.ingest(ClipClassifier.textContent("merhaba dünya", rtf: nil), source: ClipSource(), at: Date())
        let model = app.panelModel
        model.willShow()
        #expect(model.canEditSelected)
        model.requestEdit()
        model.apply(.uppercase)
        #expect(model.editing?.text.hasPrefix("MERHABA") == true)
        model.apply(.base64Decode) // Does not apply: the text stays, a note says why.
        #expect(model.editing?.note != nil && model.editing?.text.hasPrefix("MERHABA") == true)
        model.resetEdit()
        #expect(model.editing?.text == "merhaba dünya")
        model.cancelEdit()
        #expect(model.editing == nil)
        #expect(try store.counts()[.all] == 1) // Nothing was saved.
    }
}

@MainActor
struct SnippetTests {
    private func store() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
    }

    @Test func snippetsAreKeptAndFoundByName() throws {
        let store = try store()
        let old = Date().addingTimeInterval(-90 * 86_400)
        let address = try store.ingest(ClipClassifier.textContent("Hürriyet Mah. 59010", rtf: nil), source: ClipSource(), at: old)
        try store.ingest(ClipClassifier.textContent("old note", rtf: nil), source: ClipSource(), at: old)
        let id = try #require(address.id)
        try store.makeSnippet(id: id, name: "Ev adresi")

        #expect(try store.counts()[.snippets] == 1)
        #expect(try store.fetch(category: .snippets, query: "", limit: 10).first?.title == "Ev adresi")
        #expect(try store.fetch(category: .all, query: "adresi", limit: 10).map(\.id) == [id]) // By name.
        #expect(try store.fetch(category: .all, query: "Hürriyet", limit: 10).map(\.id) == [id]) // And content.

        // Limits and Clear leave it.
        #expect(try store.pruneCount(PruneLimits(retentionDays: 30, maxItems: 0, maxBytes: 0)) == 1)
        try store.prune(PruneLimits(retentionDays: 30, maxItems: 0, maxBytes: 0))
        #expect(try store.clearCount(since: nil) == 0)
        try store.clear(since: nil)
        #expect(try store.clip(id: id)?.snippetName == "Ev adresi")

        // Copying the same text again adds a history item; the snippet stays as it is.
        let again = try store.ingest(ClipClassifier.textContent("Hürriyet Mah. 59010", rtf: nil), source: ClipSource(), at: Date())
        #expect(again.id != id && again.snippetName == nil)

        try store.renameSnippet(id: id, name: "Adres")
        #expect(try store.clip(id: id)?.title == "Adres")
        try store.removeSnippet(id: id)
        #expect(try store.counts()[.snippets] == 0)
        #expect(try store.clearCount(since: nil) == 2) // An ordinary item again.
    }

    @Test func snippetsSurviveExportAndImport() throws {
        let source = try store()
        let clip = try source.ingest(ClipClassifier.textContent("Hürriyet Mah. 59010", rtf: nil), source: ClipSource(), at: Date())
        try source.makeSnippet(id: try #require(clip.id), name: "Ev adresi")
        try source.ingest(ClipClassifier.textContent("not kept", rtf: nil), source: ClipSource(), at: Date())

        let kept = try source.exportItems(since: nil, pinnedOnly: true, includeImages: false)
        #expect(kept.map(\.snippetName) == ["Ev adresi"]) // "Pinned items and snippets only".
        let file = try Transfer.json(try source.exportItems(since: nil, pinnedOnly: false, includeImages: false))
        let read = try Transfer.decoder().decode(Transfer.Document.self, from: file).items

        let target = try store()
        let records = read.compactMap { item -> Store.ImportRecord? in
            guard let text = item.text else { return nil }
            return Store.ImportRecord(content: ClipClassifier.textContent(text, rtf: nil), source: ClipSource(),
                                      firstCopiedAt: item.firstCopiedAt, lastCopiedAt: item.lastCopiedAt,
                                      timesCopied: item.timesCopied, pinned: item.pinned, snippetName: item.snippetName)
        }
        #expect(try target.importRecords(records).added == 2)
        #expect(try target.fetch(category: .snippets, query: "", limit: 10).map(\.title) == ["Ev adresi"])
        #expect(try target.importRecords(records).added == 0) // The same file again adds nothing.
        #expect(try target.counts()[.snippets] == 1)
    }

    @Test func newSnippetGetsItsTextFromTheEditor() throws {
        let store = try store()
        let snippet = try store.newSnippet(name: "Signature")
        let id = try #require(snippet.id)
        try store.updateSnippetText(id: id, "https://example.com")
        let saved = try #require(try store.clip(id: id))
        #expect(saved.text == "https://example.com" && saved.kind == .link && saved.snippetName == "Signature")
    }

    @Test func savingAsSnippetNeedsAName() throws {
        let app = AppModel()
        let store = try store()
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        try store.ingest(ClipClassifier.textContent("TR12 0006 2000 0000 0000 0000 00 is not here", rtf: nil), source: ClipSource(), at: Date())
        let model = app.panelModel
        model.willShow()
        model.requestSaveSnippet()
        model.confirmNaming() // No name: the card stays.
        #expect(model.naming != nil)
        model.naming?.name = "  Not IBAN  "
        model.confirmNaming()
        #expect(model.naming == nil)
        #expect(try store.counts()[.snippets] == 1)
        #expect(!model.canSaveSnippet && model.canRenameSelected && !model.canHideSelected)
    }
}

@MainActor
@Suite(.serialized)
struct AppFilterTests {
    private let app = AppModel()

    private func makeModel() throws -> (PanelModel, Store) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        let arc = ClipSource(bundleID: "company.thebrowser.Browser", appName: "Arc", url: nil)
        let code = ClipSource(bundleID: "com.microsoft.VSCode", appName: "Visual Studio Code", url: nil)
        try store.ingest(ClipClassifier.textContent("fatura arc", rtf: nil), source: arc, at: Date())
        try store.ingest(ClipClassifier.textContent("fatura code", rtf: nil), source: code, at: Date())
        try store.ingest(ClipClassifier.textContent("other arc", rtf: nil), source: arc, at: Date())
        app.panelModel.willShow()
        return (app.panelModel, store)
    }

    @Test func storeListsAppsAndFiltersByOne() throws {
        let (_, store) = try makeModel()
        let apps = try store.sourceApps()
        #expect(apps.map(\.name) == ["Arc", "Visual Studio Code"]) // Most used first.
        #expect(apps.first?.count == 2)
        #expect(try store.fetch(category: .all, query: "fatura", app: apps[0], limit: 10).compactMap(\.text) == ["fatura arc"])
        #expect(SourceApp(bundleID: nil, name: "Visual Studio Code").matches("code"))
    }

    @Test func atListsAppsAndChoosesOne() throws {
        let (model, _) = try makeModel()
        model.query = "@"
        #expect(model.appSuggestions.map(\.name) == ["Arc", "Visual Studio Code"])
        #expect(model.clips.count == 3) // "@…" is no search.
        model.query = "@vis"
        #expect(model.appSuggestions.map(\.name) == ["Visual Studio Code"])
        model.chooseAppSuggestion()
        #expect(model.appFilter?.name == "Visual Studio Code" && model.query.isEmpty)
        #expect(model.clips.compactMap(\.text) == ["fatura code"])
    }

    @Test func spaceChoosesTheAppAndKeepsTheSearch() throws {
        let (model, _) = try makeModel()
        model.query = "@arc fatura"
        #expect(model.appFilter?.name == "Arc" && model.query == "fatura")
        #expect(model.clips.compactMap(\.text) == ["fatura arc"])
    }

    @Test func backspaceRemovesTheAppThenTheGroup() throws {
        let (model, _) = try makeModel()
        model.query = "/text "
        model.query = "@arc "
        #expect(model.category == .text && model.appFilter != nil)
        #expect(model.clearGroup())
        #expect(model.appFilter == nil && model.category == .text)
        #expect(model.clearGroup())
        #expect(model.category == .all)
    }

    @Test func chipsKeepTheOrderTheyWereAddedIn() throws {
        let (model, _) = try makeModel()
        model.query = "@arc "
        model.query = "/text "
        #expect(model.chips == [.app, .group]) // The app chip stays first: nothing moves.
        model.query = "/links "
        #expect(model.chips == [.app, .group]) // Another group: same place.
        #expect(model.clearGroup()) // ⌫: the app chip goes first…
        #expect(model.chips == [.group])
        model.query = "@arc "
        #expect(model.chips == [.group, .app]) // …and comes back last.
        model.category = .all
        #expect(model.chips == [.app])
        model.willShow() // A new opening: no app chip.
        #expect(model.chips.isEmpty)
    }

    @Test func unknownAppIsAnOrdinarySearch() throws {
        let (model, _) = try makeModel()
        model.query = "@nowhere"
        #expect(model.appFilterTyped == nil && model.searchQuery == "@nowhere")
    }
}

@MainActor
@Suite(.serialized)
struct OpeningAndPauseTests {
    private let app = AppModel()

    @Test func panelOpensInTheGroupUsedLast() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app.installStoreForSnapshots(try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images")), hiddenKey: SoftwareHiddenKey())
        defer { app.settings.openingGroup = .all; app.settings.lastGroup = ClipCategory.all.rawValue }
        let model = app.panelModel
        app.settings.openingGroup = .last
        model.willShow()
        model.category = .links
        model.didHide()
        model.willShow()
        #expect(model.category == .links)
        #expect(app.settings.lastGroup == ClipCategory.links.rawValue) // Kept for the next launch.
        model.category = .hidden
        model.willShow()
        #expect(model.category == .all) // Hidden is locked: it never opens by itself.
        app.settings.openingGroup = .all
        model.category = .links
        model.willShow()
        #expect(model.category == .all)
    }

    @Test func pauseShortcutTogglesRecording() {
        let wasPaused = app.isPaused
        app.togglePauseFromShortcut()
        #expect(app.isPaused != wasPaused)
        app.togglePauseFromShortcut()
        #expect(app.isPaused == wasPaused)
    }
}

struct RaycastImportTests {
    /// A .rayconfig made like Raycast's: 16 header bytes + gzip(JSON), then
    /// `openssl enc -aes-256-cbc -nosalt -md sha256 -k <password>`.
    private func makeRayconfig(json: String, password: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonURL = dir.appendingPathComponent("data.json")
        try Data(json.utf8).write(to: jsonURL)
        func run(_ tool: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try run("/usr/bin/gzip", ["-k", jsonURL.path])
        let plain = dir.appendingPathComponent("plain.bin")
        try (Data(repeating: 7, count: 16) + Data(contentsOf: dir.appendingPathComponent("data.json.gz"))).write(to: plain)
        let out = dir.appendingPathComponent("Raycast 2026-11-26.rayconfig")
        try run("/usr/bin/openssl", ["enc", "-e", "-aes-256-cbc", "-nosalt", "-md", "sha256", "-k", password, "-in", plain.path, "-out", out.path])
        return out
    }

    private let sample = #"""
    {"raycast_version": "1.104.0",
     "builtin_package_clipboardHistory": {"provider_schemaVersion": 1, "clipboardHistoryRecords": [
       {"category": "text", "text": "Toplantı notu", "createdAt": "2026-11-20T09:00:00Z", "modifiedAt": "2026-11-25T10:30:00Z",
        "copyCount": 3, "applicationPath": "/System/Applications/Notes.app", "richText": "e1xydGYxIGhpfQ=="},
       {"category": "link", "text": "https://example.com/docs", "createdAt": "2026-11-21T09:00:00Z", "modifiedAt": "2026-11-21T09:00:00Z",
        "copyCount": 1, "applicationPath": "com.apple.Safari"},
       {"category": "file", "text": "report.pdf", "filePath": "/Users/me/report.pdf", "textContent": "report",
        "createdAt": "2026-11-22T09:00:00Z", "modifiedAt": "2026-11-22T09:00:00Z", "copyCount": 1},
       {"category": "image", "text": "Image (640×480)", "filePath": "/Users/me/Library/Caches/com.raycast.macos/x.png",
        "imageHash": "abc", "createdAt": "2026-11-23T09:00:00Z", "modifiedAt": "2026-11-23T09:00:00Z", "copyCount": 1}
     ]}}
    """#

    @Test func readsRaycastExports() throws {
        let url = try makeRayconfig(json: sample, password: "geçici-parola-1")
        #expect(try Transfer.detect(url) == .raycast)

        let items = try Transfer.read(url, password: "geçici-parola-1")
        #expect(items.count == 3) // The image stays in Raycast's cache.
        let note = try #require(items.first)
        #expect(note.text == "Toplantı notu" && note.timesCopied == 3)
        #expect(note.rtf.map { String(decoding: $0, as: UTF8.self) } == #"{\rtf1 hi}"#)
        #expect(note.sourceApp == "Notes" && note.sourceBundleID == "com.apple.Notes")
        #expect(note.firstCopiedAt < note.lastCopiedAt)
        #expect(items[1].sourceBundleID == "com.apple.Safari" && items[1].sourceApp == "Safari")
        #expect(items[2].kind == ClipKind.file.rawValue && items[2].files == ["/Users/me/report.pdf"])
    }

    @Test func wrongPasswordAndMissingHistory() throws {
        let url = try makeRayconfig(json: sample, password: "doğru-parola")
        #expect(throws: Transfer.TransferError.wrongPassword) { try Transfer.read(url, password: "yanlış-parola") }
        #expect(throws: Transfer.TransferError.needsPassword) { try Transfer.read(url, password: nil) }
        let empty = try makeRayconfig(json: #"{"raycast_version": "1"}"#, password: "doğru-parola")
        #expect(throws: Transfer.TransferError.noClipboardHistory) { try Transfer.read(empty, password: "doğru-parola") }
    }
}

@MainActor
@Suite(.serialized)
struct ImportFlowTests {
    private let app = AppModel()

    /// Waits for the flow's background work (a few hundred milliseconds at most).
    private func wait(_ flow: ImportFlow, until done: (ImportFlow.Step) -> Bool) async throws {
        for _ in 0..<200 {
            if done(flow.step) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The import flow did not reach the expected step")
    }

    @Test func importsATroveExportStepByStep() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        app.installStoreForSnapshots(store, hiddenKey: SoftwareHiddenKey())
        let retention = app.settings.retentionDays
        defer { app.settings.retentionDays = retention }
        app.settings.retentionDays = 30
        try store.ingest(ClipClassifier.textContent("already here", rtf: nil), source: ClipSource(), at: Date())

        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let items = [
            Transfer.Item(kind: "text", text: "already here", pinned: false, timesCopied: 1, firstCopiedAt: Date(), lastCopiedAt: Date()),
            Transfer.Item(kind: "text", text: "https://example.com", pinned: false, timesCopied: 2, firstCopiedAt: old, lastCopiedAt: old),
            Transfer.Item(kind: "text", text: "a new note", pinned: false, timesCopied: 1, firstCopiedAt: Date(), lastCopiedAt: Date()),
        ]
        let url = dir.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Transfer.json(items).write(to: url)

        let flow = ImportFlow(app: app)
        flow.open(url, as: .maccy) // The wrong source: nothing is read.
        #expect(flow.problem != nil)
        guard case .choose = flow.step else { Issue.record("Expected to stay at the first step"); return }

        flow.open(url, as: .trove)
        try await wait(flow) { if case .summary = $0 { true } else { false } }
        guard case .summary(let plan) = flow.step else { return }
        #expect(plan.total == 3 && plan.alreadyHave == 1)
        #expect(plan.kinds[.link] == 1 && plan.kinds[.text] == 2)
        #expect(plan.removedByRetention == 1) // The old link is past the 30-day limit.

        flow.keepEverything()
        #expect(app.settings.retentionDays == 0)
        guard case .summary(let kept) = flow.step else { return }
        #expect(kept.removedByRetention == 0)

        flow.startImport()
        try await wait(flow) { if case .done = $0 { true } else { false } }
        guard case .done(_, let result) = flow.step else { return }
        #expect(result.added == 2 && result.merged == 1)
        #expect(try store.counts()[.all] == 3)
    }
}

struct ReleaseCheckTests {
    @Test @MainActor func limitsAndClearKeepHiddenItems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let finding = SensitiveDetector.Finding(reason: "GitHub token", masked: "ghp_…")
        _ = try store.ingestSecret(sealed: Data([1, 2, 3]), finding: finding, characters: 40,
                                   source: ClipSource(), at: old, expiresAt: nil)
        try store.ingest(ClipClassifier.textContent("old note", rtf: nil), source: ClipSource(), at: old)
        #expect(try store.pruneCount(PruneLimits(retentionDays: 30, maxItems: 0, maxBytes: 0)) == 1) // Only the note.
        _ = try store.prune(PruneLimits(retentionDays: 30, maxItems: 1, maxBytes: 1))
        #expect(try store.clearCount(since: nil) == 0)
        try store.clear(since: nil)
        #expect(try store.counts()[.hidden] == 1)
        #expect(try store.hasSecret(finding: finding, characters: 40, at: old)) // A second import skips it.
    }

    @Test @MainActor func movingTheHistoryIsAllOrNothing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let from = root.appendingPathComponent("old"), to = root.appendingPathComponent("new")
        try fm.createDirectory(at: from.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: from.appendingPathComponent("clipboard.sqlite"))
        // Something with the same name is already in the destination: nothing moves, nothing is lost.
        try fm.createDirectory(at: to.appendingPathComponent("Images"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try Store.moveFiles(from: from, to: to) }
        #expect(fm.fileExists(atPath: from.appendingPathComponent("clipboard.sqlite").path))
        #expect(!fm.fileExists(atPath: to.appendingPathComponent("clipboard.sqlite").path))
    }

    @Test func damagedRoundCountsAreRefused() {
        #expect(throws: (any Error).self) { try Vault.deriveKey(password: "password1", salt: Data(count: 16), iterations: -1) }
        #expect(throws: (any Error).self) { try Vault.deriveKey(password: "password1", salt: Data(count: 16), iterations: 1 << 40) }
    }

    @Test func csvCellsNeverRunAsFormulas() {
        let item = Transfer.Item(kind: "text", text: "=1+2", pinned: false, timesCopied: 1,
                                 firstCopiedAt: Date(), lastCopiedAt: Date())
        let csv = String(decoding: Transfer.csv([item]), as: UTF8.self)
        #expect(csv.contains("'=1+2"))
    }
}

struct TerminalTests {
    @Test func warpLinkEncodesThePath() throws {
        let link = try #require(TerminalApp.warpLink(for: URL(fileURLWithPath: "/Users/me/My Project")))
        #expect(link.absoluteString == "warp://action/new_tab?path=/Users/me/My%20Project")
    }

    @Test func aFileOpensItsFolder() {
        let tmp = FileManager.default.temporaryDirectory
        #expect(TerminalApp.folder(for: tmp.path).standardizedFileURL == tmp.standardizedFileURL)
        #expect(TerminalApp.folder(for: "/nowhere/file.txt").path == "/nowhere")
    }
}

struct GroupCopyTests {
    private func clip(_ kind: ClipKind, _ text: String) -> Clip {
        Clip(id: 1, kind: kind, text: text, rtf: nil, byteSize: 0, contentHash: "", pinned: false,
             timesCopied: 1, firstCopiedAt: Date(), lastCopiedAt: Date())
    }

    @Test @MainActor func itemsPerKind() throws {
        let text = Copier.groupItems(clip(.text, "hello"), imageFile: nil)
        #expect(text.first?.string(forType: .string) == "hello")
        let files = Copier.groupItems(clip(.file, "/tmp/a.txt\n/tmp/b.txt"), imageFile: nil)
        #expect(files.compactMap { $0.string(forType: .fileURL) } == ["file:///tmp/a.txt", "file:///tmp/b.txt"])
        let image = Copier.groupItems(clip(.image, ""), imageFile: URL(fileURLWithPath: "/tmp/Image.png"))
        #expect(image.first?.string(forType: .fileURL) == "file:///tmp/Image.png")
        #expect(Copier.groupItems(clip(.image, ""), imageFile: nil).isEmpty)
        #expect(Copier.groupItems(clip(.secret, "••••"), imageFile: nil).isEmpty)
    }

    @Test func exportedImagesArePrivateAndExpire() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let url = try ExportFiles.write(png, for: clip(.image, ""))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: url) == png)
        #expect(url.lastPathComponent.hasSuffix(".png"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        ExportFiles.removeExpired(now: Date())
        #expect(FileManager.default.fileExists(atPath: url.path)) // Still fresh.
        ExportFiles.removeExpired(now: Date().addingTimeInterval(ExportFiles.lifetime + 60))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

extension Duration {
    var ms: String { formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))) }
}
