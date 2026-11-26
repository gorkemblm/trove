import AppKit
import SwiftUI
import OSLog
import UniformTypeIdentifiers

/// Where an import comes from, as the import window shows it.
enum ImportSource: String, CaseIterable, Identifiable, Sendable {
    case raycast, maccy, alfred, trove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raycast: "Raycast"
        case .maccy: "Maccy"
        case .alfred: "Alfred"
        case .trove: L("Trove Export")
        }
    }

    /// The letter tile's colour when the app is not installed.
    var tint: Color {
        switch self {
        case .raycast: Color(red: 0.92, green: 0.30, blue: 0.30)
        case .maccy: Color(red: 0.25, green: 0.50, blue: 0.95)
        case .alfred: Color(red: 0.45, green: 0.36, blue: 0.85)
        case .trove: .accentColor
        }
    }

    /// The installed app's own icon is shown (nothing is bundled).
    var bundleID: String? {
        switch self {
        case .raycast: "com.raycast.macos"
        case .maccy: "org.p0deje.Maccy"
        case .alfred: "com.runningwithcrayons.Alfred"
        case .trove: nil
        }
    }

    var howTo: String {
        switch self {
        case .raycast: L("In Raycast: Settings › Advanced › Export, with Clipboard History. Then choose the .rayconfig file.")
        case .maccy: L("Maccy keeps its history in its Maccy folder. The file window opens there: choose the folder.")
        case .alfred: L("Alfred keeps its clipboard in its Databases folder. The file window opens there: choose the folder.")
        case .trove: L("A file exported from Trove on this or another Mac (.clipboardexport or .json).")
        }
    }

    /// Trove's own exports always count; the others when the app is on this Mac.
    var isInstalled: Bool {
        guard let bundleID else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// What the import window lists first: the apps on this Mac, then Trove's own exports.
    static var nearby: [ImportSource] { allCases.filter { $0 != .trove && $0.isInstalled } + [.trove] }
    /// The rest, behind "Other sources": a file can come from another Mac.
    static var others: [ImportSource] { allCases.filter { !$0.isInstalled } }

    /// The real home folder (the sandbox's home is the app container).
    private static var home: URL {
        URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir), isDirectory: true)
    }

    /// The database file inside the folder that can be chosen instead.
    var databaseName: String? {
        switch self {
        case .maccy: "Storage.sqlite"
        case .alfred: "clipboard.alfdb"
        default: nil
        }
    }

    var startFolder: URL? {
        switch self {
        case .raycast: Self.home.appendingPathComponent("Downloads", isDirectory: true)
        case .maccy: Self.home.appendingPathComponent("Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy", isDirectory: true)
        case .alfred: Self.home.appendingPathComponent("Library/Application Support/Alfred/Databases", isDirectory: true)
        case .trove: nil
        }
    }

    var fileTypes: [UTType] {
        let extensions: [String] = switch self {
        case .raycast: ["rayconfig"]
        case .maccy: ["sqlite"]
        case .alfred: ["alfdb"]
        case .trove: ["clipboardexport", "json"]
        }
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }

    func accepts(_ detected: Transfer.Source) -> Bool {
        switch self {
        case .raycast: detected == .raycast
        case .maccy: detected == .maccy
        case .alfred: detected == .alfred
        case .trove: detected == .clipboardEncrypted || detected == .clipboardJSON
        }
    }
}

/// What a file holds, before anything is saved: the summary the user confirms.
struct ImportPlan: @unchecked Sendable {
    let source: ImportSource
    let records: [Store.ImportRecord]
    let secrets: [(text: String, finding: SensitiveDetector.Finding, item: Transfer.Item)]
    var total: Int { records.count + secrets.count }
    let kinds: [ClipKind: Int]
    let earliest: Date?
    let latest: Date?
    let alreadyHave: Int
    let skippedImages: Int
    /// Secrets go to Hidden, or are left out (Settings › Privacy).
    let secretsToHidden: Bool
    /// Items the current limits would remove after the import.
    let removedByRetention: Int
    let removedByItemLimit: Int
}

struct ImportResult: Sendable {
    let added: Int
    let merged: Int
    let hidden: Int
}

/// The import window's steps. The heavy work (decrypting, reading, sorting, saving) runs off
/// the main thread, so the window never freezes; each step shows its progress.
@MainActor
final class ImportFlow: ObservableObject {
    enum Step {
        case choose
        case password(ImportSource, URL)
        case reading(ImportSource, String)
        case summary(ImportPlan)
        case importing(ImportPlan, Double)
        case done(ImportSource, ImportResult)
    }

    @Published private(set) var step: Step = .choose
    @Published var password = ""
    @Published private(set) var problem: String?

    private weak var app: AppModel?
    private var work: Task<Void, Never>?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "import")

    init(app: AppModel) {
        self.app = app
    }

    var isBusy: Bool {
        switch step {
        case .reading, .importing: true
        default: false
        }
    }

    func restart() {
        work?.cancel()
        password = ""
        problem = nil
        step = .choose
    }

    // MARK: Choosing

    func choose(_ source: ImportSource, in window: NSWindow?) {
        problem = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // Maccy and Alfred: choosing their folder also lets Trove read the database's newest
        // rows, which can sit in a file next to it.
        panel.canChooseDirectories = source == .maccy || source == .alfred
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = source == .maccy || source == .alfred
        panel.prompt = L("Choose")
        panel.message = source.howTo
        if let folder = source.startFolder, FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url, as: source)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// A chosen file: checked against the source, then read (after its password, if it has one).
    func open(_ url: URL, as source: ImportSource) {
        var url = url
        if url.hasDirectoryPath, let file = source.databaseName { url = url.appendingPathComponent(file) }
        do {
            let detected = try Transfer.detect(url)
            guard source.accepts(detected) else {
                problem = String(localized: "This file is not from \(source.title). Choose another file, or another source above.")
                return
            }
            if detected.needsPassword {
                password = ""
                step = .password(source, url)
            } else {
                read(url, as: source, password: nil)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    func submitPassword() {
        guard case .password(let source, let url) = step, !password.isEmpty else { return }
        read(url, as: source, password: password)
    }

    // MARK: Reading (off the main thread)

    private func read(_ url: URL, as source: ImportSource, password: String?) {
        guard let app, app.store != nil else { return }
        problem = nil
        step = .reading(source, String(localized: "Opening the file…"))
        let toHidden = app.settings.sensitiveRule != .discard
        work = Task { [weak self] in
            // Decrypting, reading and sorting run off the main thread: the window keeps drawing.
            let outcome: Result<Sorted, Error> = await Task.detached(priority: .userInitiated) {
                defer { Transfer.removeCopies() }
                do {
                    let loaded = try Transfer.load(url, password: password)
                    await self?.setReading(source, String(localized: "Checking \(loaded.items.count.formatted()) items…"))
                    return .success(Self.sort(loaded.items, skippedImages: loaded.skippedImages))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let sorted):
                do {
                    self.password = ""
                    self.step = .summary(try self.plan(sorted, source: source, toHidden: toHidden))
                } catch {
                    self.problem = error.localizedDescription
                    self.step = .choose
                }
            case .failure(Transfer.TransferError.wrongPassword):
                self.problem = L("The password is not correct.")
                self.step = .password(source, url)
            case .failure(let error):
                self.problem = error.localizedDescription
                self.step = .choose
            }
        }
    }

    private func setReading(_ source: ImportSource, _ text: String) {
        if case .reading = step { step = .reading(source, text) }
    }

    /// The file's items, sorted: ordinary ones and those that look like secrets.
    struct Sorted: @unchecked Sendable {
        var records: [Store.ImportRecord] = []
        var secrets: [(text: String, finding: SensitiveDetector.Finding, item: Transfer.Item)] = []
        var kinds: [ClipKind: Int] = [:]
        var dates: [Date] = []
        var skippedImages = 0
    }

    nonisolated private static func sort(_ items: [Transfer.Item], skippedImages: Int) -> Sorted {
        var sorted = Sorted(skippedImages: skippedImages)
        for item in items {
            guard let content = AppModel.importContent(item) else { continue }
            sorted.dates.append(item.lastCopiedAt)
            // Snippets too: a token kept as a snippet elsewhere is not stored here as plain text.
            // It goes to Hidden with the snippet's name.
            if content.kind.isTextual, let text = content.text, let finding = SensitiveDetector.detect(text) {
                sorted.secrets.append((text, finding, item))
                continue
            }
            sorted.kinds[content.kind, default: 0] += 1
            sorted.records.append(Store.ImportRecord(
                content: content,
                source: ClipSource(bundleID: item.sourceBundleID, appName: item.sourceApp, url: item.sourceURL),
                firstCopiedAt: item.firstCopiedAt, lastCopiedAt: item.lastCopiedAt,
                timesCopied: item.timesCopied, pinned: item.pinned, snippetName: item.snippetName
            ))
        }
        return sorted
    }

    /// What the summary shows: what is new, and what the current limits would remove later.
    private func plan(_ sorted: Sorted, source: ImportSource, toHidden: Bool) throws -> ImportPlan {
        guard let app, let store = app.store else { throw CocoaError(.featureUnsupported) }
        let alreadyHave = try store.existingCount(ofHashes: sorted.records.filter { $0.snippetName == nil }.map(\.content.hash))
        // Kept items (pinned, snippets) are never removed by limits.
        let prunable = sorted.records.filter { !$0.pinned && $0.snippetName == nil }
        var byRetention = 0
        if app.settings.retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(app.settings.retentionDays) * 86_400)
            byRetention = prunable.filter { $0.lastCopiedAt < cutoff }.count
        }
        var byLimit = 0
        if app.settings.maxItems > 0 {
            let after = try store.totalCount() + sorted.records.count - alreadyHave - byRetention
            byLimit = max(0, after - app.settings.maxItems)
        }
        return ImportPlan(source: source, records: sorted.records, secrets: toHidden ? sorted.secrets : [], kinds: sorted.kinds,
                          earliest: sorted.dates.min(), latest: sorted.dates.max(), alreadyHave: alreadyHave,
                          skippedImages: sorted.skippedImages, secretsToHidden: toHidden,
                          removedByRetention: byRetention, removedByItemLimit: byLimit)
    }

    // MARK: Limits

    /// "Keep Them": the limits that would remove imported items are lifted (never lowered).
    func keepEverything() {
        guard case .summary(let plan) = step, let app else { return }
        if plan.removedByRetention > 0 { app.settings.retentionDays = 0 }
        if plan.removedByItemLimit > 0 { app.settings.maxItems = 0 }
        read(plan)
    }

    private func read(_ plan: ImportPlan) {
        // The counts change with the limits: shown again without reading the file again.
        let updated = ImportPlan(source: plan.source, records: plan.records, secrets: plan.secrets, kinds: plan.kinds,
                                 earliest: plan.earliest, latest: plan.latest, alreadyHave: plan.alreadyHave,
                                 skippedImages: plan.skippedImages, secretsToHidden: plan.secretsToHidden,
                                 removedByRetention: app?.settings.retentionDays == 0 ? 0 : plan.removedByRetention,
                                 removedByItemLimit: app?.settings.maxItems == 0 ? 0 : plan.removedByItemLimit)
        step = .summary(updated)
    }

    // MARK: Saving (off the main thread, in batches)

    func startImport() {
        guard case .summary(let plan) = step, let app, let store = app.store else { return }
        let hiddenKey = plan.secretsToHidden && !plan.secrets.isEmpty ? app.loadHiddenKeyForImport() : nil
        step = .importing(plan, 0)
        work = Task { [weak self] in
            // Saved in small batches; between them the window draws, so it never stalls.
            var added = 0, merged = 0, hidden = 0
            let total = Double(max(1, plan.total))
            do {
                let batch = 200
                for start in stride(from: 0, to: plan.records.count, by: batch) {
                    let result = try store.importRecords(Array(plan.records[start..<min(start + batch, plan.records.count)]))
                    added += result.added
                    merged += result.merged
                    self?.setProgress(plan, Double(min(start + batch, plan.records.count)) / total)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                if let hiddenKey {
                    for (index, secret) in plan.secrets.enumerated() {
                        // The same file imported again: its hidden items are not added twice.
                        if try store.hasSecret(finding: secret.finding, characters: secret.text.count, at: secret.item.lastCopiedAt) {
                            merged += 1
                            continue
                        }
                        let sealed = try SealedSecret.seal(Data(secret.text.utf8), to: hiddenKey.publicKey)
                        let saved = try store.ingestSecret(sealed: sealed, finding: secret.finding, characters: secret.text.count,
                                                           source: ClipSource(bundleID: secret.item.sourceBundleID, appName: secret.item.sourceApp, url: nil),
                                                           at: secret.item.lastCopiedAt, expiresAt: nil)
                        if let name = secret.item.snippetName, let id = saved.id { try store.renameSecret(id: id, name: name) }
                        hidden += 1
                        self?.setProgress(plan, Double(plan.records.count + index + 1) / total)
                    }
                }
                guard let self else { return }
                self.log.info("Imported \(added) new, \(merged) merged, \(hidden) hidden from \(plan.source.rawValue, privacy: .public)")
                self.app?.importDidFinish()
                // A beat at 100 %, so the bar is seen to finish.
                self.setProgress(plan, 1)
                try? await Task.sleep(for: .milliseconds(250))
                self.step = .done(plan.source, ImportResult(added: added, merged: merged, hidden: hidden))
            } catch {
                guard let self else { return }
                // What was saved stays (each batch is complete); the rest can be imported again,
                // and items already there are merged.
                self.problem = String(localized: "The import stopped: \(error.localizedDescription) \(added.formatted()) items were saved; importing again merges them.")
                self.app?.importDidFinish()
                self.step = .summary(plan)
            }
        }
    }

    #if SNAPSHOTS
    /// `make layout` only: shows a step without a file.
    func preview(_ step: Step, problem: String? = nil) {
        self.step = step
        self.problem = problem
    }
    #endif

    private func setProgress(_ plan: ImportPlan, _ value: Double) {
        if case .importing = step { step = .importing(plan, min(1, value)) }
    }
}
