import SwiftUI

/// Design B: categories on the left, list in the middle, preview and details on the right.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if model.panelLocked {
                PanelLockView(unlock: model.requestPanelUnlock)
            } else {
                content
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: PanelController.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelController.cornerRadius, style: .continuous)
                .strokeBorder(Theme.panelStroke, lineWidth: 1)
        )
    }

    private var content: some View {
        VStack(spacing: 0) {
            searchBar
            Theme.divider.frame(height: 1)
            HStack(spacing: 0) {
                SidebarView(model: model).frame(width: 196)
                Theme.divider.frame(width: 1)
                ClipListView(model: model).frame(width: 330)
                Theme.divider.frame(width: 1)
                DetailView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Theme.divider.frame(height: 1)
            FooterView(model: model)
        }
        .overlay {
            if let clips = model.pendingDelete {
                DeleteConfirmation(clips: clips, cancel: model.cancelDelete, confirm: model.confirmDelete)
            } else if model.naming != nil {
                NamingCard(model: model)
            } else if model.actionsOpen {
                ActionsMenu(model: model)
            } else if !model.groupSuggestions.isEmpty {
                // Under the search text, over the list.
                GroupSuggestionsView(model: model)
                    .padding(.top, 50)
                    .padding(.leading, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
            if model.category != .all {
                GroupChip(category: model.category) { model.category = .all }
            }
            TextField(
                "Search",
                text: $model.query,
                prompt: Text(verbatim: model.category.searchPrompt).foregroundColor(Theme.faint)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .focused($searchFocused)
            Text(verbatim: model.category == .all ? "\(model.category.title) · \(model.resultLabel)" : model.resultLabel)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
            if model.canSelectSeveral {
                SelectModeButton(active: model.selecting, action: model.toggleSelecting)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: PanelModel

    /// Sized so that every group fits the panel (see the "Sidebar fits" layout check).
    static let rowHeight: CGFloat = 32
    static let subrowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let groups = model.visibleGroups
            ForEach(groups.filter { $0 != .pinned && $0 != .hidden }) { category in
                if category.isSubgroup { subrow(category) } else { row(category) }
            }
            Theme.divider.frame(height: 1).padding(.vertical, 6).padding(.horizontal, 4)
            if groups.contains(.pinned) { row(.pinned) }
            row(.hidden)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        // Never taller than the panel: with too many groups the bottom is cut, the panel keeps its size.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(Theme.sidebar)
    }

    /// A sub-group of Text: indented, smaller, same selection style.
    private func subrow(_ category: ClipCategory) -> some View {
        let selected = model.category == category
        let focused = model.focusArea == .sidebar
        return Button {
            model.choose(category)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.symbol).font(.system(size: 11)).frame(width: 16)
                Text(category.title).lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
                Text(model.countLabel(category))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Theme.accentText.opacity(0.8) : Theme.faint)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(selected ? Theme.accentText : Theme.muted)
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .frame(height: SidebarView.subrowHeight)
            .background(
                selected ? (focused ? Theme.accentFillFocused : Theme.accentFill) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func row(_ category: ClipCategory) -> some View {
        let selected = model.category == category
        let focused = model.focusArea == .sidebar
        return Button {
            model.choose(category)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.symbol).font(.system(size: 13)).frame(width: 18)
                Text(category.title)
                Spacer()
                Text(model.countLabel(category))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Theme.accentText.opacity(0.8) : Theme.faint)
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Theme.accentText : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: SidebarView.rowHeight)
            .background(
                selected ? (focused ? Theme.accentFillFocused : Theme.accentFill) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: - List

struct ClipListView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if model.hiddenLocked {
            HiddenLockedView(model: model)
        } else if model.sections.isEmpty {
            EmptyStateView(
                symbol: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                title: model.query.isEmpty ? (model.hasAnyClips ? "Nothing here yet" : "Nothing copied yet") : "No results",
                message: model.query.isEmpty
                    ? "Copy something and it shows up here."
                    : "Nothing in \(model.category.title) matches “\(model.query)”."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sections) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(section.clips) { clip in
                                ClipRow(clip: clip, selected: clip.id == model.selectedID, active: model.focusArea == .list,
                                        check: model.selecting ? (clip.id.map(model.picked.contains) ?? false) : nil)
                                    .id(clip.rowID)
                                    .overlay {
                                        RowMouseArea(
                                            onClick: { modifiers, count in click(clip, modifiers: modifiers, count: count) },
                                            dragItems: { model.dragItems(for: model.dragClips(from: clip)) },
                                            onDragStart: model.dragWillStart,
                                            onDragEnd: { dropped in model.dragged(model.dragClips(from: clip), dropped: dropped) }
                                        )
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                // A new list each time the panel opens: no row keeps its look (a check mark, an
                // old time) from the last time, when the window was off screen.
                .id(model.showCount)
            }
        }
    }

    /// A plain click selects (or, in select mode, picks); ⌘ and ⇧ pick; a double click copies.
    private func click(_ clip: Clip, modifiers: NSEvent.ModifierFlags, count: Int) {
        if model.click(clip, modifiers: modifiers) { return }
        if count >= 2 {
            if !model.selecting { model.copy(clip) }
        } else {
            model.select(clip)
        }
    }
}

/// The chosen group at the start of the search field. ⌫ in an empty search or ✕ removes it.
struct GroupChip: View {
    let category: ClipCategory
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: category.symbol).font(.system(size: 11))
            Text(verbatim: category.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L("Back to All (⌫)"))
        }
        .foregroundStyle(Theme.accentText)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }
}

/// The groups that match "/…" in the search field.
struct GroupSuggestionsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let suggestions = model.groupSuggestions
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, category in
                Button { model.chooseGroupSuggestion(category) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol).font(.system(size: 12)).frame(width: 18)
                        Text(verbatim: category.title).font(.system(size: 13))
                        Spacer(minLength: 12)
                        Text(model.countLabel(category)).font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(index == model.groupPick ? Theme.accentText.opacity(0.8) : Theme.faint)
                    }
                    .foregroundStyle(index == model.groupPick ? Theme.accentText : Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(index == model.groupPick ? Theme.accentFillFocused : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            Theme.divider.frame(height: 1).padding(.vertical, 4)
            HStack(spacing: 12) {
                HStack(spacing: 4) { Kbd("↵"); Text("Go to group") }
                HStack(spacing: 4) { Kbd("esc"); Text("Cancel") }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .padding(6)
        .frame(width: 260)
        .background(Theme.dialog, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.panelStroke))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

/// The search-bar switch for select mode.
struct SelectModeButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(active ? Theme.selectTint : Theme.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L("Select several items (⌘⇧S, ⌘-click, ⇧-click or ⇧↓)"))
    }
}

struct ClipRow: View {
    let clip: Clip
    let selected: Bool
    /// False while the sidebar has the arrow keys: the selection then looks dimmed.
    var active = true
    /// In select mode: whether the row is picked. Nil outside select mode (no circle).
    var check: Bool? = nil

    private var fill: Color {
        if let check { return check ? Theme.accentFill : .clear } // Picked rows match the sidebar's selection.
        return selected ? (active ? Theme.rowSelected : Theme.rowSelectedInactive) : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            if let check {
                Image(systemName: check ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(check ? Theme.selectTint : Theme.faint)
                    .frame(width: 16)
            }
            ClipIcon(clip: clip, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(clip.subtitle)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if clip.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(fill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            // In select mode the keyboard position shows as an outline.
            if check != nil, selected {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.selectTint.opacity(0.7), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }
}

struct ClipIcon: View {
    let clip: Clip
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(Theme.iconFill)
            if let rgba = clip.rgba {
                Circle()
                    .fill(Color(red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255).opacity(rgba.a))
                    .frame(width: size * 0.5, height: size * 0.5)
            } else {
                Image(systemName: clip.isImageFiles ? "photo" : clip.kind.symbol)
                    .font(.system(size: size * 0.48))
                    .foregroundStyle(Theme.text.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var model: PanelModel

    /// Left: the state (paused, picked items) and the one action that belongs to this item.
    /// Right: always the same two buttons in the same place, Paste and Actions. Everything
    /// else is in the Actions menu (⌘K), and every action keeps its own shortcut.
    var body: some View {
        HStack(spacing: 2) {
            if let paused = model.pauseStatus {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange).padding(.leading, 8)
                Text(paused).font(.system(size: 12.5)).foregroundStyle(.orange).monospacedDigit().padding(.trailing, 6)
            }
            if model.hasGroupSelection {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.selectTint).padding(.leading, 8)
                Text(String(localized: "\(model.picked.count.formatted()) selected"))
                    .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.text)
            } else if let secondary = model.secondaryAction {
                FooterAction(title: secondary.title, symbol: secondary.symbol, keys: ["⌘", "↵"]) { model.performSecondaryAction() }
            } else if let clip = model.selected, clip.kind.isTextual {
                FooterAction(title: L("Plain Text"), symbol: "textformat", keys: ["⇧", "↵"]) { model.copySelected(plainText: true) }
            } else if model.pauseStatus == nil {
                Image(systemName: "list.clipboard").foregroundStyle(Theme.muted).padding(.leading, 8)
                Text("Trove").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if model.hasGroupSelection || model.selected != nil {
                FooterAction(title: model.returnTitle, keys: ["↵"], prominent: true) { model.copySelected(plainText: false) }
                Theme.divider.frame(width: 1, height: 16).padding(.horizontal, 4)
            }
            FooterAction(title: L("Actions"), keys: ["⌘", "K"], highlighted: model.actionsOpen) { model.toggleActions() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(Theme.footer)
    }
}

/// The ⌘K menu: every action for the selection, searchable, with its shortcut.
struct ActionsMenu: View {
    @ObservedObject var model: PanelModel
    @FocusState private var focused: Bool

    var body: some View {
        let actions = model.filteredActions
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.001) // A click outside closes the menu.
                .contentShape(Rectangle())
                .onTapGesture(perform: model.closeActions)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    if actions.isEmpty {
                        Text("No matching actions")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                    }
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0, actions[index - 1].section != action.section {
                            Theme.divider.frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
                        }
                        row(action, picked: index == model.actionPick)
                    }
                }
                .padding(6)
                Theme.divider.frame(height: 1)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    TextField("Search actions…", text: $model.actionFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
            }
            .frame(width: 330)
            .background(Theme.dialog, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
            .padding(.trailing, 10)
            .padding(.bottom, 50) // Just above the footer.
        }
        .onAppear { focused = true }
    }

    private func row(_ action: PanelModel.PanelAction, picked: Bool) -> some View {
        let tint = action.destructive ? Theme.destructive : (picked ? Theme.accentText : Theme.text)
        return Button { model.run(action) } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbol).font(.system(size: 12.5)).frame(width: 18)
                Text(verbatim: action.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    ForEach(action.keys, id: \.self) { Kbd($0) }
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(picked ? Theme.accentFillFocused : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct FooterAction: View {
    let title: String
    var symbol: String? = nil
    let keys: [String]
    var enabled = true
    /// The main action: slightly bolder.
    var prominent = false
    /// Shown pressed, for a menu that is open.
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Text(title).font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { Kbd($0) }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(highlighted ? Theme.kbdFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4) // Same width when disabled, so other buttons stay put.
    }
}

/// The list area of Hidden before Touch ID.
struct HiddenLockedView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let count = model.counts[.hidden] ?? 0
        VStack(spacing: 8) {
            Image(systemName: count > 0 ? "lock.fill" : "lock").font(.system(size: 26)).foregroundStyle(Theme.faint)
            (count > 0 ? Text("Hidden items are locked") : Text("No hidden items"))
                .font(.system(size: 14, weight: .semibold))
            Group {
                if count == 0 {
                    Text("API keys, tokens, private keys, card numbers and IBANs you copy are kept here, sealed with Touch ID.")
                } else if count == 1 {
                    Text("Unlock with Touch ID to see 1 item.")
                } else {
                    Text("Unlock with Touch ID to see \(count.formatted()) items.")
                }
            }
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if count > 0 {
                Button(action: model.unlockHidden) {
                    HStack(spacing: 6) {
                        Image(systemName: "touchid")
                        Text("Unlock")
                        Kbd("↵")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.kbdFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The whole panel while it is locked: no history behind it, only the way to unlock.
struct PanelLockView: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Theme.faint)
            Text("Trove is locked").font(.system(size: 17, weight: .semibold))
            Text("Unlock with Touch ID or your password to see your history.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Button(action: unlock) {
                HStack(spacing: 6) {
                    Image(systemName: "touchid")
                    Text("Unlock")
                    Kbd("↵")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Theme.kbdFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.top, 6)
            Text("Esc closes").font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The panel's dialog style: a small card aligned left, a coloured eyebrow, and key hints in
/// place of filled buttons. Used for every dialog in the panel.
struct PanelDialog<Content: View>: View {
    let eyebrow: LocalizedStringKey
    let symbol: String
    let tint: Color
    let title: Text
    let cancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                    Text(eyebrow).font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)
                }
                .foregroundStyle(tint)
                title.font(.system(size: 17, weight: .semibold))
                content
            }
            .padding(20)
            .frame(width: 400, alignment: .leading)
            .background(Theme.dialog, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        }
    }
}

/// A key hint that is also a button: label and key cap. The primary one carries the tint.
struct KeyHint: View {
    let title: LocalizedStringKey
    let key: String
    var primary = false
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
                    .foregroundStyle(primary ? Theme.text : Theme.muted)
                Text(verbatim: key)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primary ? Color.white : Theme.kbdText)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(primary ? tint : Theme.kbdFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Moving an item to Hidden (with an optional name), or renaming a hidden item.
struct NamingCard: View {
    @ObservedObject var model: PanelModel
    @FocusState private var focused: Bool

    private var hiding: Bool { model.naming?.purpose == .hide }

    var body: some View {
        PanelDialog(eyebrow: "Hidden", symbol: hiding ? "lock.fill" : "pencil", tint: .accentColor,
                    title: hiding ? Text("Name this item") : Text("Rename hidden item"), cancel: model.cancelNaming) {
            if hiding {
                Text("It is sealed with this Mac’s Secure Enclave and leaves your history. Search finds it by name only.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Image(systemName: "tag").font(.system(size: 13)).foregroundStyle(Theme.faint)
                TextField("Name (optional)", text: Binding(
                    get: { model.naming?.name ?? "" },
                    set: { model.naming?.name = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Theme.iconFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
            .padding(.top, 2)
            HStack(spacing: 16) {
                Spacer()
                KeyHint(title: "Cancel", key: "esc", action: model.cancelNaming)
                KeyHint(title: hiding ? "Hide" : "Save", key: "↵", primary: true, action: model.confirmNaming)
            }
            .padding(.top, 4)
        }
        .onAppear { focused = true }
    }
}

/// Asks before an item is deleted. Covers the panel, so nothing behind it moves.
struct DeleteConfirmation: View {
    let clips: [Clip]
    let cancel: () -> Void
    let confirm: () -> Void

    /// Up to three titles, one line each, then how many more.
    private var lines: [String] {
        if clips.count == 1 { return [clips[0].title] }
        var lines = clips.prefix(3).map(\.title)
        if clips.count > 3 { lines.append(String(localized: "and \((clips.count - 3).formatted()) more")) }
        return lines
    }

    private var note: Text {
        let pinned = clips.filter(\.pinned).count
        if clips.count == 1 {
            return pinned > 0 ? Text("It is pinned. This cannot be undone.") : Text("This cannot be undone.")
        }
        return pinned > 0 ? Text("\(pinned.formatted()) of them are pinned. This cannot be undone.") : Text("This cannot be undone.")
    }

    var body: some View {
        PanelDialog(eyebrow: "Delete", symbol: "trash.fill", tint: Theme.destructive,
                    title: clips.count == 1 ? Text("Delete this item?") : Text("Delete \(clips.count.formatted()) items?"),
                    cancel: cancel) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).lineLimit(clips.count == 1 ? 2 : 1)
                }
            }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.iconFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            note
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 16) {
                Spacer()
                KeyHint(title: "Cancel", key: "esc", action: cancel)
                KeyHint(title: "Delete", key: "↵", primary: true, tint: Theme.destructive, action: confirm)
            }
            .padding(.top, 4)
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.faint)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
