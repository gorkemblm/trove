import AppKit
import SwiftUI

/// The short animated demos of "How Trove Works" (onboarding, the menu bar menu, ⌘K) and of the
/// README. `make demos` renders them from the real panel with sample data, in English and Turkish
/// (Resources/<language>.lproj/Demos/<name>.gif); the README uses the English ones (Docs/demos).
enum Demo: String, CaseIterable, Identifiable {
    case browse, groups, apps, actions, editor, textInImages, snippets, selectAndDrag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: L("Find and paste")
        case .groups: L("Jump to a group with /")
        case .apps: L("Only one app with @")
        case .actions: L("Every action with ⌘K")
        case .editor: L("Edit and transform with ⌘E")
        case .textInImages: L("Search the text in screenshots")
        case .snippets: L("Keep snippets with ⌘S")
        case .selectAndDrag: L("Pick several, drag anywhere")
        }
    }

    var detail: String {
        switch self {
        case .browse:
            L("⌥Space opens Trove over any app. Type to search, ↑↓ to choose, ↵ to paste into the app you were in. ← → move between the groups and the items.")
        case .groups:
            L("Type / and the start of a group’s name: Images, Links, Code… ↵ or a space opens it, and it stays as a chip. ⌫ in an empty search takes it away.")
        case .apps:
            L("Type @ and an app’s name to see only what you copied there. Combine it with a group and a search: [Images] [Arc] invoice.")
        case .actions:
            L("⌘K lists everything you can do with the selected item, with its shortcut. Type to filter; the shortcuts also work without the menu.")
        case .editor:
            L("⌘E turns the preview into an editor. Change the text, or use the menus: case, clean-up, lines, URL, Base64, JSON. ⌘↵ pastes the result; Esc cancels.")
        case .textInImages:
            L("Trove reads the text in images on this Mac. Search finds a screenshot by a word in it, the word is boxed, and ⌘⇧C copies the matching line.")
        case .snippets:
            L("⌘S keeps an item as a named snippet: no limit and no Clear removes it, and search finds it by name. ⌘E edits it later.")
        case .selectAndDrag:
            L("⌘-click, ⇧-click or ⌘⇧S picks several items. ↵ pastes them all, ⌘D deletes them, and dragging takes them to any app or folder.")
        }
    }

    /// The key hints shown under the title.
    var keys: [String] {
        switch self {
        case .browse: ["⌥", "Space", "↑↓", "↵"]
        case .groups: ["/"]
        case .apps: ["@"]
        case .actions: ["⌘", "K"]
        case .editor: ["⌘", "E"]
        case .textInImages: ["⌘", "⇧", "C"]
        case .snippets: ["⌘", "S"]
        case .selectAndDrag: ["⌘", "⇧", "S"]
        }
    }

    /// The animation in the app's language (Resources/<language>.lproj/Demos).
    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "gif", subdirectory: "Demos") }
}

/// An animated GIF, playing in a loop (NSImageView plays GIFs by itself).
struct AnimatedImage: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = url.flatMap(NSImage.init(contentsOf:))
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        let image = url.flatMap(NSImage.init(contentsOf:))
        if view.image?.name() != url?.lastPathComponent {
            image?.setName(url?.lastPathComponent)
            view.image = image
        }
    }
}

/// "How Trove Works": one demo at a time, with its title, keys and a short explanation.
/// ← → or the dots move between them.
struct DemoTour: View {
    @State private var index = 0
    var compact = false

    private var demo: Demo { Demo.allCases[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            AnimatedImage(url: demo.url)
                .aspectRatio(PanelController.size.width / PanelController.size.height, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .id(demo)
            HStack(spacing: 8) {
                Text(verbatim: demo.title).font(.system(size: compact ? 14 : 16, weight: .semibold))
                Spacer(minLength: 8)
                HStack(spacing: 3) { ForEach(Array(demo.keys.enumerated()), id: \.offset) { Kbd($0.element) } }
            }
            Text(verbatim: demo.detail)
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: compact ? 48 : 54, alignment: .top)
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).disabled(index == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                HStack(spacing: 6) {
                    ForEach(Demo.allCases.indices, id: \.self) { dot in
                        Circle().fill(dot == index ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: 6, height: 6)
                            .onTapGesture { index = dot }
                    }
                }
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(index == Demo.allCases.count - 1)
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
        .animation(.easeInOut(duration: 0.15), value: index)
    }

    private func move(_ delta: Int) {
        index = min(max(index + delta, 0), Demo.allCases.count - 1)
    }
}
