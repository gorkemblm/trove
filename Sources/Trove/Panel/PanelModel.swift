import AppKit
import LocalAuthentication
import OSLog

enum ClipCategory: Int, CaseIterable, Identifiable, Sendable {
    case all, text, links, images, files, pinned, hidden
    /// Sub-groups of Text.
    case code, emails, phones, colors, data
    /// Sub-group of Images: screenshots saved to the screenshot folder.
    case screenshots

    /// Top to bottom, as the sidebar shows them; ↑↓ follow this order.
    static let sidebarOrder: [ClipCategory] = [.all, .text, .code, .data, .emails, .phones, .colors, .links, .images, .screenshots, .files, .pinned, .hidden]
    /// ⌘1 … ⌘5.
    static let numbered: [ClipCategory] = [.all, .text, .links, .images, .files]

    var isSubgroup: Bool { [.code, .data, .emails, .phones, .colors, .screenshots].contains(self) }
    /// The group a sub-group belongs to.
    var parent: ClipCategory? {
        switch self {
        case .code, .data, .emails, .phones, .colors: .text
        case .screenshots: .images
        default: nil
        }
    }
    /// Groups the user can turn off in Settings. All, Text and Hidden always show.
    static let optional: [ClipCategory] = [.code, .data, .emails, .phones, .colors, .links, .images, .screenshots, .files, .pinned]

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: L("All")
        case .text: L("Text")
        case .links: L("Links")
        case .images: L("Images")
        case .files: L("Files")
        case .pinned: L("Pinned")
        case .hidden: L("Hidden")
        case .code: L("Code")
        case .emails: L("Emails")
        case .phones: L("Phones")
        case .colors: L("Colors")
        case .data: L("Data")
        case .screenshots: L("Screenshots")
        }
    }

    /// The search field placeholder, a full sentence per group (word order differs by language).
    var searchPrompt: String {
        switch self {
        case .all: L("Search clipboard, or type / for a group…")
        case .text: L("Search text…")
        case .links: L("Search links…")
        case .images: L("Search images…")
        case .files: L("Search files…")
        case .pinned: L("Search pinned items…")
        case .hidden: L("Search hidden items…")
        case .code: L("Search code…")
        case .emails: L("Search emails…")
        case .phones: L("Search phone numbers…")
        case .colors: L("Search colors…")
        case .data: L("Search data…")
        case .screenshots: L("Search screenshots…")
        }
    }

    /// The English name: the translation key of `title`.
    var englishTitle: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        case .pinned: "Pinned"
        case .hidden: "Hidden"
        case .code: "Code"
        case .emails: "Emails"
        case .phones: "Phones"
        case .colors: "Colors"
        case .data: "Data"
        case .screenshots: "Screenshots"
        }
    }

    /// Other words that find the group after "/", in both languages.
    var aliases: [String] {
        switch self {
        case .all: ["everything", "hepsi"]
        case .text: ["txt", "yazı"]
        case .links: ["url", "web", "bağlantı"]
        case .images: ["img", "image", "photo", "picture", "foto", "resim"]
        case .screenshots: ["screenshot", "capture", "shot", "ekran", "görüntü"]
        case .files: ["file", "doc", "dosya", "belge"]
        case .pinned: ["pin", "favorite", "sabit"]
        case .hidden: ["secret", "lock", "password", "şifre", "kilit"]
        case .code: ["swift", "script", "kod"]
        case .emails: ["mail", "eposta", "e-posta"]
        case .phones: ["tel", "phone", "telefon", "numara"]
        case .colors: ["color", "colour", "hex", "rgb", "renk"]
        case .data: ["json", "xml", "yaml", "csv", "veri"]
        }
    }

    /// The group's names in English and Turkish, the shown one first.
    var names: [String] {
        var names = [title, englishTitle]
        if let path = Bundle.main.path(forResource: "tr", ofType: "lproj"), let turkish = Bundle(path: path) {
            names.append(turkish.localizedString(forKey: englishTitle, value: englishTitle, table: nil))
        }
        return names
    }

    /// Case, accents and the Turkish dotted and dotless i do not matter: "gor" finds Görseller.
    static func fold(_ text: String) -> String { text.searchFolded }

    /// How well the typed text names this group; lower is better, nil is no match.
    /// 0: the shown name starts with it. 1: the other language's name does.
    /// 2: an alias does (from two letters on, so one letter keeps the list short).
    func matchRank(_ typed: String) -> Int? {
        let typed = Self.fold(typed)
        guard !typed.isEmpty else { return 0 }
        func starts(_ name: String) -> Bool {
            let folded = Self.fold(name)
            return folded.hasPrefix(typed) || folded.split(whereSeparator: { $0 == " " || $0 == "-" }).contains { $0.hasPrefix(typed) }
        }
        if starts(title) { return 0 }
        if names.dropFirst().contains(where: starts) { return 1 }
        if typed.count >= 2, aliases.contains(where: starts) { return 2 }
        return nil
    }

    func matches(_ typed: String) -> Bool { matchRank(typed) != nil }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .text: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .files: "doc"
        case .pinned: "pin"
        case .hidden: "lock"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .emails: "envelope"
        case .phones: "phone"
        case .colors: "paintpalette"
        case .data: "curlybraces"
        case .screenshots: "camera.viewfinder"
        }
    }

    /// Kinds shown in this category. Nil means every kind except hidden items.
    var kinds: [ClipKind]? {
        switch self {
        case .all, .pinned: nil
        case .hidden: [.secret]
        case .text: [.text, .code, .data, .email, .phone, .color]
        case .data: [.data]
        case .code: [.code]
        case .emails: [.email]
        case .phones: [.phone]
        case .colors: [.color]
        case .links: [.link]
        case .images, .screenshots: [.image]
        case .files: [.file]
        }
    }
}

@MainActor
final class PanelModel: ObservableObject {
    struct Section: Identifiable {
        let id: String
        let title: String
        let clips: [Clip]
    }

    /// Where the arrow keys act. The search field keeps keyboard focus in both areas.
    enum FocusArea {
        case list, sidebar
    }

    static let fetchLimit = 2000

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            focusArea = .list // Typing returns to the items.
            if groupFilter != nil { groupPick = 0 }
            // "/ima " with a space: the first matching group is chosen, the rest is the search.
            if applyGroupBySpace() { return }
            // While "/…" is typed the list keeps its items: that text names a group, it is no search.
            guard searchQuery != searchQuery(for: oldValue) else { return }
            reload(resetSelection: true)
        }
    }

    // MARK: - Groups by typing "/"

    /// The text after "/" while a group is being typed, nil otherwise. Text that matches no
    /// group is an ordinary search, so paths such as "/usr/bin" still find items.
    var groupFilter: String? { groupFilter(for: query) }

    private func groupFilter(for text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(" ") else { return nil }
        let typed = String(text.dropFirst())
        return visibleGroups.contains { $0.matches(typed) } ? typed : nil
    }

    /// The groups that match what follows "/", in sidebar order.
    var groupSuggestions: [ClipCategory] {
        guard let filter = groupFilter else { return [] }
        // Best match first; equal matches keep the sidebar order.
        return visibleGroups.enumerated()
            .compactMap { index, group in group.matchRank(filter).map { (rank: $0, index: index, group: group) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.group)
    }

    /// The highlighted suggestion.
    @Published var groupPick = 0

    /// What the list searches for. A "/group" being typed searches for nothing.
    var searchQuery: String { searchQuery(for: query) }

    private func searchQuery(for text: String) -> String {
        groupFilter(for: text) == nil ? text : ""
    }

    func moveGroupPick(_ delta: Int) {
        let count = groupSuggestions.count
        guard count > 0 else { return }
        groupPick = min(max(groupPick + delta, 0), count - 1)
    }

    /// ↵ or Tab in the suggestions.
    func chooseGroupSuggestion() {
        let suggestions = groupSuggestions
        guard suggestions.indices.contains(groupPick) else { NSSound.beep(); return }
        applyGroup(suggestions[groupPick], search: "")
    }

    func chooseGroupSuggestion(_ category: ClipCategory) {
        applyGroup(category, search: "")
    }

    private func applyGroupBySpace() -> Bool {
        guard query.hasPrefix("/"), let space = query.firstIndex(of: " ") else { return false }
        let typed = String(query[query.index(after: query.startIndex)..<space])
        guard !typed.isEmpty else { return false }
        let ranked = visibleGroups.compactMap { group in group.matchRank(typed).map { (rank: $0, group: group) } }
        guard let group = ranked.min(by: { $0.rank < $1.rank })?.group else { return false }
        applyGroup(group, search: String(query[query.index(after: space)...]))
        return true
    }

    private func applyGroup(_ group: ClipCategory, search: String) {
        query = search // Inside query's didSet this does not run didSet again: reload below.
        groupPick = 0
        if category == group {
            reload(resetSelection: true)
        } else {
            choose(group) // Reloads, and asks for Touch ID for Hidden.
        }
        if !search.isEmpty { focusArea = .list }
    }

    /// ⌫ in an empty search: back to All.
    func clearGroup() -> Bool {
        guard query.isEmpty, category != .all else { return false }
        category = .all
        focusArea = .list
        return true
    }
    @Published var focusArea: FocusArea = .list
    @Published var category: ClipCategory = .all {
        didSet {
            guard category != oldValue else { return }
            endSelecting()
            reload(resetSelection: true)
        }
    }
    @Published private(set) var sections: [Section] = []
    @Published private(set) var counts: [ClipCategory: Int] = [:]
    @Published var selectedID: Int64? {
        didSet {
            if editing != nil, selectedID != oldValue { editing = nil } // The editor belongs to one item.
            if let pending = pendingDelete, pending.count == 1, pending.first?.id != selectedID { pendingDelete = nil }
            loadDetail()
        }
    }
    /// The name card: moving an item to Hidden, or renaming a hidden item.
    struct NamingRequest {
        enum Purpose { case hide, rename }
        let purpose: Purpose
        let clip: Clip
        var name: String
    }

    @Published var naming: NamingRequest?

    /// The editor (⌘E): the right side becomes a text editor with the transforms above it.
    struct EditSession: Equatable {
        var text: String
        let original: String
        /// What the transform could not do ("This is not valid JSON."), shown under the text.
        var note: String?
    }

    @Published var editing: EditSession?
    /// Incremented to give the keyboard to the editor (after the actions menu closes).
    @Published private(set) var editorFocusRequest = 0

    /// The items waiting for delete confirmation (⌘D, then ↵). Nil when no confirmation is shown.
    @Published private(set) var pendingDelete: [Clip]?

    /// Select mode: rows show check circles, and a click picks or unpicks an item.
    /// ⌘-click, ⇧-click, ⇧↑↓ and ⌘A turn it on; Esc turns it off.
    @Published private(set) var selecting = false
    /// The picked items, for drag, copy and delete as a group.
    @Published private(set) var picked: Set<Int64> = []
    /// Where a ⇧-click or ⇧↑↓ range starts.
    private var anchorID: Int64?
    /// The selected item with its full content. List items carry only a short text.
    @Published private(set) var detail: Clip?
    /// The coloured preview (or table) of the selected code or data item.
    @Published private(set) var preview: PreviewContent?
    /// The re-indented form of the selected JSON or XML, when it differs from the original.
    private(set) var formattedCopy: String?
    /// The text read in the selected image, line by line, with each line's place in it.
    @Published private(set) var imageTextLayout: RecognizedText?
    /// For a search: the line under each image the text in it matched ("…invoice 2026-114…").
    @Published private(set) var imageSnippets: [Int64: String] = [:]
    /// The panel lock screen is showing. No history is loaded while it is.
    @Published private(set) var panelLocked = false
    /// Hidden opens after Touch ID and locks again when the panel closes.
    @Published private(set) var hiddenUnlocked = false
    /// The revealed content of the selected hidden item.
    @Published private(set) var revealedText: String?
    @Published private(set) var revealFailed = false
    private var authContext: LAContext?
    private var unlocking = false
    /// Incremented each time the panel opens, so the view focuses the search field.
    @Published private(set) var focusRequest = 0
    /// Incremented each time the panel opens: the list is built anew (see ClipListView).
    @Published private(set) var showCount = 0

    private(set) var clips: [Clip] = []
    private(set) var isVisible = false
    private weak var app: AppModel?
    private let images = NSCache<NSNumber, NSImage>()
    private let log = Logger(subsystem: AppInfo.bundleID, category: "panel")

    init(app: AppModel) {
        self.app = app
        images.countLimit = 40
    }

    var selected: Clip? {
        guard let selectedID else { return nil }
        return clips.first { $0.id == selectedID }
    }

    var hasAnyClips: Bool { (counts[.all] ?? 0) > 0 }

    private func loadDetail() {
        revealedText = nil
        revealFailed = false
        preview = nil
        formattedCopy = nil
        imageTextLayout = nil
        guard let selectedID else {
            detail = nil
            return
        }
        detail = (try? app?.store?.clip(id: selectedID)) ?? selected
        if let detail {
            if detail.kind == .image || detail.isImageFiles {
                imageTextLayout = RecognizedText.load(layout: detail.recognizedLayout, text: detail.recognizedText)
            }
            preview = PreviewContent.make(for: detail, limit: PreviewContent.detailLimit)
            if detail.kind == .data, let text = detail.text, text.count <= 1_000_000,
               let format = ContentDetector.DataFormat(rawValue: detail.format ?? ""), format.canPrettyPrint,
               let pretty = Formatting.pretty(text, format: format),
               pretty != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                formattedCopy = pretty
            }
        }
        if let detail, detail.kind == .secret, hiddenUnlocked {
            revealedText = app?.reveal(detail, context: authContext)
            revealFailed = revealedText == nil
        }
    }

    // MARK: - Hidden

    var hiddenLocked: Bool { category == .hidden && !hiddenUnlocked }

    /// Asks for Touch ID, then shows the hidden items.
    func unlockHidden() {
        guard !hiddenUnlocked, !unlocking, (counts[.hidden] ?? 0) > 0 else { return }
        unlocking = true
        app?.authenticate(reason: String(localized: "show hidden clipboard items")) { [weak self] context in
            guard let self else { return }
            unlocking = false
            guard let context, isVisible else { return }
            authContext = context
            hiddenUnlocked = true
            reload(resetSelection: true)
            focusList()
        }
    }

    func requestPanelUnlock() {
        app?.unlockPanel()
    }

    /// "Recording paused" or "Paused until 14:20" for the footer, nil while recording.
    var pauseStatus: String? { app?.pauseDescription }

    func lockHidden() {
        authContext?.invalidate()
        authContext = nil
        hiddenUnlocked = false
        revealedText = nil
        revealFailed = false
    }

    /// Snapshot mode only: shows Hidden without Touch ID (the snapshot key needs none).
    func unlockForSnapshots() {
        hiddenUnlocked = true
        reload(resetSelection: true)
    }

    func countLabel(_ category: ClipCategory) -> String {
        (counts[category] ?? 0).formatted()
    }

    var resultLabel: String {
        if hiddenLocked { return L("Locked") }
        return clips.count >= Self.fetchLimit ? "\(Self.fetchLimit.formatted())+" : clips.count.formatted()
    }

    // MARK: - Lifecycle

    func willShow() {
        isVisible = true
        if !isVisible(category) { category = .all } // Turned off in Settings while selected.
        pendingDelete = nil
        naming = nil
        editing = nil
        actionsOpen = false
        actionFilter = ""
        endSelecting()
        lockHidden()
        focusArea = .list
        if query.isEmpty {
            reload(resetSelection: true)
        } else {
            query = "" // didSet reloads
        }
        showCount += 1
        focusRequest += 1
    }

    func didHide() {
        isVisible = false
        app?.panelDidHide()
        app?.closeLargePreview()
        pendingDelete = nil
        lockHidden()
    }

    func storeDidChange() {
        if isVisible { reload(resetSelection: false) }
    }

    /// Locking drops the loaded history from memory; unlocking loads it again.
    func setPanelLocked(_ locked: Bool) {
        guard locked != panelLocked else { return }
        panelLocked = locked
        if locked {
            pendingDelete = nil
            sections = []
            clips = []
            selectedID = nil
            lockHidden()
        } else {
            reload(resetSelection: true)
            focusRequest += 1
        }
    }

    func reload(resetSelection: Bool) {
        guard !panelLocked else { return }
        guard let store = app?.store else {
            sections = []
            clips = []
            counts = [:]
            return
        }
        let start = ContinuousClock.now
        do {
            let search = searchQuery
            let fetched = hiddenLocked ? [] : try store.fetch(category: category, query: search, limit: Self.fetchLimit)
            counts = try store.counts()
            sections = Self.group(fetched, splitPinned: search.isEmpty && category != .pinned)
            clips = sections.flatMap(\.clips)
            // An empty group has nothing to move through: the arrows stay in the groups.
            // While searching, they stay with the results, even when there are none.
            if clips.isEmpty, search.isEmpty { focusArea = .sidebar }
            imageSnippets = Self.snippets(for: clips, search: search, store: store)
            // Picks that left the list (deleted, or filtered out by the search) are dropped.
            if !picked.isEmpty { picked.formIntersection(clips.compactMap(\.id)) }
            if resetSelection || selected == nil {
                selectedID = clips.first?.id
            } else {
                loadDetail() // Counts and dates of the selected item may have changed.
            }
        } catch {
            log.error("Loading clips failed: \(error.localizedDescription, privacy: .public)")
        }
        let elapsed = ContinuousClock.now - start
        if elapsed > .milliseconds(50) {
            log.notice("Slow reload: \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        }
    }

    static func group(_ clips: [Clip], splitPinned: Bool, now: Date = Date()) -> [Section] {
        var result: [Section] = []
        var rest = clips
        if splitPinned {
            let pinned = clips.filter(\.pinned)
            if !pinned.isEmpty { result.append(Section(id: "pinned", title: L("Pinned"), clips: pinned)) }
            rest = clips.filter { !$0.pinned }
        }
        let calendar = Calendar.current
        let buckets: [(title: String, test: (Date) -> Bool)] = [
            (L("Today"), { calendar.isDateInToday($0) }),
            (L("Yesterday"), { calendar.isDateInYesterday($0) }),
            (L("Last 7 Days"), { now.timeIntervalSince($0) < 7 * 86_400 }),
            (L("Last 30 Days"), { now.timeIntervalSince($0) < 30 * 86_400 }),
            (L("Older"), { _ in true }),
        ]
        var grouped = Array(repeating: [Clip](), count: buckets.count)
        for clip in rest {
            let index = buckets.firstIndex { $0.test(clip.lastCopiedAt) } ?? buckets.count - 1
            grouped[index].append(clip)
        }
        for (index, bucket) in buckets.enumerated() where !grouped[index].isEmpty {
            result.append(Section(id: bucket.title, title: bucket.title, clips: grouped[index]))
        }
        return result
    }

    // MARK: - Navigation

    func move(_ delta: Int) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex { $0.id == selectedID } ?? -1
        let next = min(max(current + delta, 0), clips.count - 1)
        selectedID = clips[next].id
        anchorID = selectedID
    }

    /// ↑↓ in the sidebar. Stops at the first and last category.
    /// The sidebar without the groups turned off in Settings.
    var visibleGroups: [ClipCategory] {
        let hidden = app?.settings.hiddenGroups ?? []
        return ClipCategory.sidebarOrder.filter { !hidden.contains($0.rawValue) }
    }

    func isVisible(_ category: ClipCategory) -> Bool { visibleGroups.contains(category) }

    func moveCategory(_ delta: Int) {
        let all = visibleGroups
        let index = all.firstIndex(of: category) ?? 0
        category = all[min(max(index + delta, 0), all.count - 1)]
    }

    func focusSidebar() {
        focusArea = .sidebar
    }

    /// Moves the arrows to the items. An empty group keeps them in the sidebar.
    /// A locked Hidden group asks for Touch ID first.
    func focusList() {
        if hiddenLocked {
            unlockHidden()
            return
        }
        guard !clips.isEmpty else { return }
        focusArea = .list
    }

    /// A click on a category shows its items and keeps the arrows in the list.
    func choose(_ category: ClipCategory) {
        self.category = category
        focusArea = clips.isEmpty ? .sidebar : .list
        if hiddenLocked { unlockHidden() } // A click is a clear request; arrows are not.
    }

    /// ⌘1 … ⌘5.
    func selectCategory(number: Int) {
        guard ClipCategory.numbered.indices.contains(number - 1) else { return }
        let target = ClipCategory.numbered[number - 1]
        guard isVisible(target) else { NSSound.beep(); return }
        self.category = target
    }

    /// Esc clears the search first. Returns true when the panel should close.
    func escape() -> Bool {
        if selecting {
            endSelecting()
            return false
        }
        guard query.isEmpty else {
            query = ""
            return false
        }
        return true
    }

    // MARK: - Actions

    func select(_ clip: Clip) {
        if selecting {
            togglePick(clip)
            return
        }
        selectedID = clip.id
        anchorID = clip.id
        focusArea = .list
    }

    // MARK: - Picking several items

    /// The items in list order. Two or more make a group selection.
    var pickedClips: [Clip] { clips.filter { $0.id.map(picked.contains) ?? false } }
    var hasGroupSelection: Bool { picked.count > 1 }

    /// What ↵, ⌘D and a drag act on: the group, or the selected item.
    var actionClips: [Clip] {
        hasGroupSelection ? pickedClips : (selected.map { [$0] } ?? [])
    }

    /// Hidden items stay sealed: they cannot be copied, dragged or deleted as a group.
    var canSelectSeveral: Bool { category != .hidden }

    private func canPick(_ clip: Clip) -> Bool { clip.kind != .secret && clip.id != nil }

    /// A click with ⌘ or ⇧. Returns false for a plain click.
    func click(_ clip: Clip, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.shift) {
            pickRange(to: clip)
            return true
        }
        if modifiers.contains(.command) {
            togglePick(clip)
            return true
        }
        return false
    }

    /// The search-bar button.
    func toggleSelecting() {
        if selecting { endSelecting(); return }
        guard canSelectSeveral else { NSSound.beep(); return }
        startSelecting()
    }

    /// Turns select mode on. The selected item is the first pick.
    private func startSelecting() {
        guard !selecting else { return }
        selecting = true
        if let clip = selected, canPick(clip), let id = clip.id { picked = [id] }
        anchorID = selectedID
        focusArea = .list
    }

    func endSelecting() {
        selecting = false
        if !picked.isEmpty { picked = [] }
    }

    func togglePick(_ clip: Clip) {
        guard canSelectSeveral, canPick(clip), let id = clip.id else { NSSound.beep(); return }
        startSelecting()
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        selectedID = id
        anchorID = id
        focusArea = .list
    }

    /// ⇧-click: every item from the anchor to this one.
    func pickRange(to clip: Clip) {
        guard canSelectSeveral, canPick(clip) else { NSSound.beep(); return }
        startSelecting()
        let anchor = anchorID ?? selectedID ?? clip.id
        guard let from = clips.firstIndex(where: { $0.id == anchor }),
              let to = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        picked = Set(clips[min(from, to)...max(from, to)].filter(canPick).compactMap(\.id))
        selectedID = clip.id
        focusArea = .list
    }

    /// ⇧↑ and ⇧↓.
    func extendSelection(_ delta: Int) {
        guard canSelectSeveral, !clips.isEmpty else { NSSound.beep(); return }
        if !selecting { startSelecting() }
        let current = clips.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), clips.count - 1)
        pickRange(to: clips[next])
    }

    /// ⌘A.
    func pickAll() {
        guard canSelectSeveral, !clips.isEmpty else { NSSound.beep(); return }
        startSelecting()
        picked = Set(clips.filter(canPick).compactMap(\.id))
    }

    /// A row drag starts: a picked row brings the whole group, any other row comes alone.
    func dragClips(from clip: Clip) -> [Clip] {
        guard canPick(clip) else { return [] }
        if hasGroupSelection, let id = clip.id, picked.contains(id) { return pickedClips }
        return [clip]
    }

    func dragged(_ clips: [Clip], dropped: Bool) {
        app?.finishDrag(clips, dropped: dropped)
    }

    func dragWillStart() {
        app?.beginDrag()
    }

    func dragItems(for clips: [Clip]) -> [DragItem] {
        app?.dragItems(for: clips) ?? []
    }

    func copy(_ clip: Clip, plainText: Bool = false) {
        app?.copy(clip, plainText: plainText)
    }

    func copySelected(plainText: Bool) {
        if hasGroupSelection {
            app?.copy(pickedClips, plainText: plainText)
            return
        }
        guard let clip = selected else { NSSound.beep(); return }
        if clip.kind == .secret {
            guard let revealedText else { NSSound.beep(); return }
            app?.copySecret(clip, text: revealedText)
            return
        }
        copy(clip, plainText: plainText)
    }

    /// The ⌘↵ action of the selected item, if it has one.
    enum SecondaryAction: Equatable {
        case reveal([String])
        case compose([String])
        case call(String)
        case copyFormatted(String)
        case open(URL)
        case saveImage

        var title: String {
            switch self {
            case .open: L("Open in Browser")
            case .saveImage: L("Save Image…")
            case .reveal: L("Show in Finder")
            case .compose: L("Compose Email")
            case .call: L("Call")
            case .copyFormatted: L("Copy Formatted")
            }
        }

        var symbol: String {
            switch self {
            case .open: "safari"
            case .saveImage: "square.and.arrow.down"
            case .reveal: "folder"
            case .compose: "envelope"
            case .call: "phone"
            case .copyFormatted: "curlybraces"
            }
        }
    }

    /// Uses the full item: list items carry only a preview.
    var secondaryAction: SecondaryAction? {
        guard !hasGroupSelection, let detail else { return nil }
        switch detail.kind {
        case .image:
            // Screenshots have a file to show; images from the clipboard can be saved as one.
            let paths = detail.revealPaths
            return paths.isEmpty ? .saveImage : .reveal(paths)
        case .file:
            let paths = detail.revealPaths
            return paths.isEmpty ? nil : .reveal(paths)
        case .email:
            return ContentDetector.emailAddresses(in: detail.text ?? "").map(SecondaryAction.compose)
        case .phone:
            return ContentDetector.phoneNumber(in: detail.text ?? "").map(SecondaryAction.call)
        case .data:
            return formattedCopy.map(SecondaryAction.copyFormatted)
        case .link:
            return detail.linkURL.map(SecondaryAction.open)
        default:
            return nil
        }
    }

    /// ⌘↵.
    func performSecondaryAction() {
        switch secondaryAction {
        case .reveal(let paths): app?.revealInFinder(paths)
        case .compose(let addresses): app?.composeEmail(to: addresses)
        case .call(let number): app?.call(number)
        case .copyFormatted(let text): app?.copyText(text, message: L("Copied Formatted"))
        case .open(let url): app?.openLink(url)
        case .saveImage: if let detail { app?.saveImage(detail) }
        case nil: NSSound.beep()
        }
    }

    /// "Paste" or "Copy", after Settings › General › Return Key.
    var returnTitle: String { app?.settings.returnAction == .copy ? L("Copy") : L("Paste") }
    var returnPastes: Bool { app?.settings.returnAction != .copy }

    /// A colour chip: copies (or pastes) the colour in that form.
    func copyColor(_ value: String, format: String) {
        app?.copyText(value, message: String(localized: "Copied \(format)"))
    }

    // MARK: - Editor (⌘E)

    /// Text items, and images with text (their text is edited). Hidden items stay sealed.
    var canEditSelected: Bool {
        guard !hasGroupSelection, let detail else { return false }
        return (detail.kind.isTextual && detail.text != nil) || imageText != nil
    }

    func requestEdit() {
        guard canEditSelected, let detail else { NSSound.beep(); return }
        let text = detail.kind.isTextual ? (detail.text ?? "") : (imageText ?? "")
        editing = EditSession(text: text, original: text)
        focusArea = .list
    }

    func apply(_ transform: TextTransform) {
        guard let session = editing else { return }
        guard let result = transform.apply(session.text) else {
            editing?.note = String(localized: "“\(transform.title)” does not apply to this text.")
            NSSound.beep()
            return
        }
        editing?.text = result
        editing?.note = nil
        editorFocusRequest += 1
    }

    func resetEdit() {
        guard let session = editing else { return }
        editing = EditSession(text: session.original, original: session.original)
        editorFocusRequest += 1
    }

    func cancelEdit() {
        editing = nil
        focusRequest += 1
    }

    /// ⌘↵: the edited text is pasted (or copied) and saved in history as a new item.
    func finishEdit() {
        guard let text = editing?.text, !text.isEmpty else { NSSound.beep(); return }
        editing = nil
        app?.useEditedText(text)
    }

    // MARK: - Text in images

    /// The text Vision read in the selected image, when there is any.
    var imageText: String? {
        guard !hasGroupSelection else { return nil }
        return imageTextLayout?.plainText.nilIfEmpty
    }

    /// The words of the current search ("/group" text is no search).
    var searchTerms: [String] { RecognizedText.terms(of: searchQuery) }

    /// Lines of the selected image that contain the searched words.
    var imageMatches: [RecognizedText.Line] {
        guard !hasGroupSelection else { return [] }
        return imageTextLayout?.lines(matching: searchTerms) ?? []
    }

    /// ⌘⇧C: while searching, the lines that matched; otherwise all the text in the image.
    func copyImageText() {
        let matches = imageMatches
        guard !matches.isEmpty else { copyAllImageText(); return }
        let text = matches.map(\.text).joined(separator: "\n")
        let message = matches.count == 1 ? String(localized: "Copied: \(matches[0].text)") : String(localized: "Copied \(matches.count.formatted()) Lines")
        app?.copyText(text, message: message)
    }

    func copyAllImageText() {
        guard let imageText else { NSSound.beep(); return }
        app?.copyText(imageText, message: L("Copied All Text from Image"))
    }

    /// Images found by the text in them (not by their name) get a line of that text in the list.
    private static func snippets(for clips: [Clip], search: String, store: Store) -> [Int64: String] {
        let terms = RecognizedText.terms(of: search)
        guard !terms.isEmpty else { return [:] }
        let images = clips.filter { clip in
            guard clip.kind == .image || clip.isImageFiles else { return false }
            let title = clip.title
            return !terms.allSatisfy { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        guard let texts = try? store.recognizedTexts(ids: images.compactMap(\.id)) else { return [:] }
        return texts.compactMapValues { RecognizedText.snippet(of: $0, terms: terms) }
    }

    /// The text indexer read an image: the selected one shows its text at once.
    func recognitionDidUpdate(id: Int64) {
        guard isVisible, selectedID == id else { return }
        loadDetail()
    }

    /// File and folder items open in a terminal (⌘T), when one is installed.
    var canOpenInTerminal: Bool {
        !hasGroupSelection && detail?.kind == .file && app?.terminal != nil
    }

    func openInTerminal() {
        guard canOpenInTerminal, let detail else { NSSound.beep(); return }
        app?.openInTerminal(detail.filePaths)
    }

    /// The eye button: text, code, data and images open in a larger window.
    var canOpenLargePreview: Bool {
        guard let detail else { return false }
        return [.text, .code, .data, .image].contains(detail.kind) || (detail.isImageFiles && detail.imageFile != nil)
    }

    func openLargePreview() {
        guard canOpenLargePreview, let detail else { return }
        app?.openLargePreview(detail)
    }

    func togglePinSelected() {
        guard !hasGroupSelection, let clip = selected, clip.kind != .secret else { NSSound.beep(); return }
        app?.setPinned(clip, !clip.pinned)
        reload(resetSelection: false)
    }

    // MARK: - Hidden on purpose

    /// Text items can be hidden; a revealed hidden item can go back.
    var canHideSelected: Bool { !hasGroupSelection && (selected.map { $0.kind.isTextual } ?? false) }
    var canMoveBackSelected: Bool { selected?.kind == .secret && revealedText != nil }
    var canRenameSelected: Bool { selected?.kind == .secret && hiddenUnlocked }

    /// ⌘⇧H: hides a text item (asks for a name first), or moves a revealed hidden item back.
    func requestHideToggle() {
        if canMoveBackSelected { moveBackSelected(); return }
        guard canHideSelected, let clip = selected else { NSSound.beep(); return }
        naming = NamingRequest(purpose: .hide, clip: clip, name: "")
    }

    /// ⌘R in Hidden.
    func requestRename() {
        guard canRenameSelected, let clip = selected else { NSSound.beep(); return }
        naming = NamingRequest(purpose: .rename, clip: clip, name: clip.format ?? "")
    }

    func confirmNaming() {
        guard let request = naming else { return }
        naming = nil
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch request.purpose {
        case .hide: app?.hideItem(request.clip, name: name)
        case .rename: app?.renameHidden(request.clip, name: name)
        }
        focusRequest += 1
    }

    func cancelNaming() {
        naming = nil
        focusRequest += 1
    }

    func moveBackSelected() {
        guard let clip = selected, clip.kind == .secret, let revealedText else { NSSound.beep(); return }
        app?.unhideItem(clip, text: revealedText)
    }

    /// ⌘⌫ and the footer button: shows the confirmation. Nothing is deleted yet.
    func requestDelete() {
        let clips = actionClips
        guard !clips.isEmpty else { NSSound.beep(); return }
        pendingDelete = clips
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    /// ↵ in the confirmation.
    func confirmDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        delete(pending)
    }

    private func delete(_ doomed: [Clip]) {
        let ids = Set(doomed.compactMap(\.id))
        guard let index = clips.firstIndex(where: { $0.id == selectedID }) ?? clips.firstIndex(where: { $0.id.map(ids.contains) ?? false }) else { return }
        // The nearest item that stays: below first, then above.
        let after = clips[index...].first { !($0.id.map(ids.contains) ?? false) }?.id
        let neighbour = after ?? clips[..<index].last { !($0.id.map(ids.contains) ?? false) }?.id
        for clip in doomed { app?.delete(clip) }
        endSelecting()
        reload(resetSelection: false)
        if let neighbour, clips.contains(where: { $0.id == neighbour }) {
            selectedID = neighbour
        }
    }

    func openSettings() {
        closeActions()
        app?.openSettings()
    }

    /// The keyboard goes back to the search field (after Settings closes).
    func refocusSearch() {
        focusRequest += 1
    }

    // MARK: - Actions menu (⌘K)

    /// One line of the actions menu. Every action also has its own shortcut, shown on the right.
    struct PanelAction: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var keys: [String] = []
        var destructive = false
        /// Actions of one section sit together; a divider separates sections.
        let section: Int
        let run: @MainActor () -> Void
    }

    @Published private(set) var actionsOpen = false
    @Published var actionFilter = "" {
        didSet { if actionFilter != oldValue { actionPick = 0 } }
    }
    @Published private(set) var actionPick = 0

    /// What can be done now: in the editor, with the selected item, with the picked items, or with none.
    var actions: [PanelAction] {
        var list: [PanelAction] = []
        if editing != nil {
            list.append(PanelAction(id: "finishEdit", title: returnPastes ? L("Paste Edited Text") : L("Copy Edited Text"),
                                    symbol: "doc.on.clipboard", keys: ["⌘", "↵"], section: 0) { [weak self] in self?.finishEdit() })
            for (index, group) in TextTransform.Group.allCases.enumerated() {
                for transform in group.transforms {
                    list.append(PanelAction(id: "transform." + transform.rawValue, title: transform.title, symbol: group.symbol,
                                            section: index + 1) { [weak self] in self?.apply(transform) })
                }
            }
            list.append(PanelAction(id: "resetEdit", title: L("Undo All Changes"), symbol: "arrow.uturn.backward", section: 9) { [weak self] in
                self?.resetEdit()
            })
            list.append(PanelAction(id: "cancelEdit", title: L("Cancel Editing"), symbol: "xmark", keys: ["esc"], section: 9) { [weak self] in
                self?.cancelEdit()
            })
            return list
        }
        if hasGroupSelection {
            let count = picked.count.formatted()
            list.append(PanelAction(id: "paste", title: returnPastes ? String(localized: "Paste \(count) Items") : String(localized: "Copy \(count) Items"),
                                    symbol: "doc.on.clipboard", keys: ["↵"], section: 0) { [weak self] in self?.copySelected(plainText: false) })
            list.append(PanelAction(id: "all", title: L("Select All"), symbol: "checklist", keys: ["⌘", "A"], section: 1) { [weak self] in self?.pickAll() })
            list.append(PanelAction(id: "done", title: L("Stop Selecting"), symbol: "xmark.circle", keys: ["esc"], section: 1) { [weak self] in self?.endSelecting() })
            list.append(PanelAction(id: "delete", title: String(localized: "Delete \(count) Items…"), symbol: "trash", keys: ["⌘", "D"],
                                    destructive: true, section: 2) { [weak self] in self?.requestDelete() })
        } else if let clip = selected {
            list.append(PanelAction(id: "paste", title: returnTitle, symbol: "doc.on.clipboard", keys: ["↵"], section: 0) { [weak self] in
                self?.copySelected(plainText: false)
            })
            if clip.kind.isTextual {
                list.append(PanelAction(id: "plain", title: returnPastes ? L("Paste as Plain Text") : L("Copy as Plain Text"),
                                        symbol: "textformat", keys: ["⇧", "↵"], section: 0) { [weak self] in self?.copySelected(plainText: true) })
            }
            if let secondary = secondaryAction {
                list.append(PanelAction(id: "secondary", title: secondary.title, symbol: secondary.symbol, keys: ["⌘", "↵"], section: 0) { [weak self] in
                    self?.performSecondaryAction()
                })
            }
            if imageText != nil {
                let matches = imageMatches.count
                if matches > 0 {
                    list.append(PanelAction(id: "imageLine", title: matches == 1 ? L("Copy Matching Line") : String(localized: "Copy \(matches.formatted()) Matching Lines"),
                                            symbol: "text.viewfinder", keys: ["⌘", "⇧", "C"], section: 0) { [weak self] in self?.copyImageText() })
                    list.append(PanelAction(id: "imageText", title: L("Copy All Text from Image"), symbol: "doc.plaintext",
                                            section: 0) { [weak self] in self?.copyAllImageText() })
                } else {
                    list.append(PanelAction(id: "imageText", title: L("Copy All Text from Image"), symbol: "text.viewfinder",
                                            keys: ["⌘", "⇧", "C"], section: 0) { [weak self] in self?.copyAllImageText() })
                }
            }
            if canEditSelected {
                list.append(PanelAction(id: "edit", title: L("Edit and Transform…"), symbol: "pencil.and.list.clipboard",
                                        keys: ["⌘", "E"], section: 0) { [weak self] in self?.requestEdit() })
            }
            if canOpenInTerminal, let terminal = app?.terminal {
                list.append(PanelAction(id: "terminal", title: String(localized: "Open in \(terminal.name)"), symbol: "terminal",
                                        keys: ["⌘", "T"], section: 0) { [weak self] in self?.openInTerminal() })
            }
            if canOpenLargePreview {
                list.append(PanelAction(id: "preview", title: L("Open Preview"), symbol: "eye", section: 0) { [weak self] in self?.openLargePreview() })
            }
            if clip.kind != .secret {
                list.append(PanelAction(id: "pin", title: clip.pinned ? L("Unpin") : L("Pin"), symbol: clip.pinned ? "pin.slash" : "pin",
                                        keys: ["⌘", "P"], section: 1) { [weak self] in self?.togglePinSelected() })
            }
            if canMoveBackSelected {
                list.append(PanelAction(id: "unhide", title: L("Move Back to History"), symbol: "lock.open", keys: ["⌘", "⇧", "H"], section: 1) { [weak self] in
                    self?.moveBackSelected()
                })
            } else if canHideSelected {
                list.append(PanelAction(id: "hide", title: L("Move to Hidden"), symbol: "lock", keys: ["⌘", "⇧", "H"], section: 1) { [weak self] in
                    self?.requestHideToggle()
                })
            }
            if canRenameSelected {
                list.append(PanelAction(id: "rename", title: L("Rename Hidden Item"), symbol: "pencil", keys: ["⌘", "R"], section: 1) { [weak self] in
                    self?.requestRename()
                })
            }
            if canSelectSeveral {
                list.append(PanelAction(id: "select", title: L("Select Several Items"), symbol: "checkmark.circle", keys: ["⌘", "⇧", "S"], section: 1) { [weak self] in
                    self?.toggleSelecting()
                })
            }
            list.append(PanelAction(id: "delete", title: L("Delete…"), symbol: "trash", keys: ["⌘", "D"], destructive: true, section: 2) { [weak self] in
                self?.requestDelete()
            })
        }
        list.append(PanelAction(id: "settings", title: L("Settings…"), symbol: "gearshape", keys: ["⌘", ","], section: 3) { [weak self] in
            self?.openSettings()
        })
        return list
    }

    /// The actions whose title contains the typed text (case and accents do not matter).
    var filteredActions: [PanelAction] {
        let typed = ClipCategory.fold(actionFilter.trimmingCharacters(in: .whitespaces))
        guard !typed.isEmpty else { return actions }
        return actions.filter { ClipCategory.fold($0.title).contains(typed) }
    }

    func toggleActions() {
        if actionsOpen { closeActions(); return }
        guard !panelLocked else { return }
        actionFilter = ""
        actionPick = 0
        actionsOpen = true
    }

    func closeActions() {
        guard actionsOpen else { return }
        actionsOpen = false
        actionFilter = ""
        // The keyboard goes back to where it was: the editor, or the search field.
        if editing != nil { editorFocusRequest += 1 } else { focusRequest += 1 }
    }

    func moveActionPick(_ delta: Int) {
        let count = filteredActions.count
        guard count > 0 else { return }
        actionPick = min(max(actionPick + delta, 0), count - 1)
    }

    /// ↵ in the menu.
    func runPickedAction() {
        let list = filteredActions
        guard list.indices.contains(actionPick) else { NSSound.beep(); return }
        run(list[actionPick])
    }

    func run(_ action: PanelAction) {
        closeActions()
        action.run()
    }

    func image(for clip: Clip) -> NSImage? {
        let key = NSNumber(value: clip.rowID)
        if let cached = images.object(forKey: key) { return cached }
        guard let data = app?.store?.imageData(for: clip), let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}
