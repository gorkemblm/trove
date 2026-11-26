import AppKit
import SwiftUI

/// What the preview shows for code and data: coloured text, or a table for CSV and TSV.
/// Built once per selection (see PanelModel), not on every redraw.
struct PreviewContent {
    enum Body {
        case text(AttributedString)
        case table([[String]])
    }

    let body: Body
    /// True when minified JSON or XML is shown re-indented. Copy still gives the original.
    let formatted: Bool

    /// Characters the detail preview shows; the large preview shows everything.
    static let detailLimit = 20_000

    static func make(for clip: Clip, limit: Int?) -> PreviewContent? {
        guard clip.kind == .code || clip.kind == .data, let text = clip.text else { return nil }
        let format = clip.kind == .data ? ContentDetector.DataFormat(rawValue: clip.format ?? "") : nil
        if format == .csv || format == .tsv {
            let separator: Character = format == .tsv ? "\t" : (text.contains(";") && !text.contains(",") ? ";" : ",")
            return PreviewContent(body: .table(Formatting.table(text, separator: separator, limit: limit == nil ? 5_000 : 200)), formatted: false)
        }
        var display = text
        var formatted = false
        if let format, format.canPrettyPrint, Formatting.isMinified(text), text.count <= 1_000_000,
           let pretty = Formatting.pretty(text, format: format) {
            display = pretty
            formatted = true
        }
        if let limit { display = String(display.prefix(limit)) }
        let rules = SyntaxHighlighter.ruleSet(kind: clip.kind, format: clip.format)
        return PreviewContent(body: .text(SyntaxHighlighter.attributed(display, ruleSet: rules)), formatted: formatted)
    }
}

/// The table of a CSV or TSV preview. The first row is the header.
struct DataTableView: View {
    let rows: [[String]]
    var maxColumns = 12

    var body: some View {
        let columns = min(rows.map(\.count).max() ?? 0, maxColumns)
        // At least as large as the visible area, so a small table sits at the top left.
        GeometryReader { proxy in
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(.system(size: 12, weight: index == 0 ? .semibold : .regular, design: .monospaced))
                                .lineLimit(1)
                                .frame(minWidth: 60, maxWidth: 220, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(index == 0 ? Theme.iconFill : (index % 2 == 0 ? Theme.rowSelectedInactive : Color.clear))
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.trailing, 40) // Room for the preview button.
            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
        }
        }
    }
}

/// A small round button over the preview.
struct PreviewButton: View {
    var symbol = "eye"
    var help = L("Open a larger preview")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Theme.kbdFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}

struct FormattedBadge: View {
    var body: some View {
        Text("Formatted")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Theme.kbdFill, in: Capsule())
            .help("Shown re-indented. Copy gives the original; ⌘↵ copies this form.")
    }
}

// MARK: - Large preview

/// Long text in an AppKit text view: fast for large content, selectable, no wrapping for code.
struct AttributedTextView: NSViewRepresentable {
    let text: NSAttributedString
    let wraps: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = !wraps
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 18, height: 16)
        if !wraps {
            view.isHorizontallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        view.textStorage?.setAttributedString(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSTextView)?.textStorage?.setAttributedString(text)
    }
}

struct LargePreviewView: View {
    let clip: Clip
    let image: NSImage?
    /// The words of the panel's search: highlighted in the image and in its text.
    var terms: [String] = []
    var actionTitle = L("Copy")
    let copy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ClipIcon(clip: clip, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(details).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                }
                Spacer(minLength: 12)
                if formatted { FormattedBadge() }
                Button(action: copy) {
                    HStack(spacing: 6) {
                        Text(actionTitle).font(.system(size: 12.5, weight: .medium))
                        Kbd("↵")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.kbdFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .padding(.top, 34) // Below the window buttons.
            .padding(.bottom, 12)
            Theme.divider.frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Theme.text)
    }

    private var format: ContentDetector.DataFormat? {
        clip.kind == .data ? ContentDetector.DataFormat(rawValue: clip.format ?? "") : nil
    }

    private var formatted: Bool {
        guard let format, format.canPrettyPrint, let text = clip.text else { return false }
        return Formatting.isMinified(text)
    }

    private var details: String {
        var parts = [clip.sourceAppName, clip.kind == .code || clip.kind == .data ? clip.format.map(L) : clip.kind.title].compactMap { $0 }
        if clip.kind == .image, let w = clip.imageWidth, let h = clip.imageHeight { parts.append("\(w) × \(h)") }
        if clip.kind.isTextual {
            let lines = clip.lineCount.formatted(), characters = clip.characterCount.formatted()
            parts.append(String(localized: "\(lines) lines · \(characters) characters"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if clip.kind == .image || clip.isImageFiles {
            if let image {
                if let text = RecognizedText.load(layout: clip.recognizedLayout, text: clip.recognizedText) {
                    // The image, and next to it the text read in it: select any part and copy it.
                    HStack(spacing: 0) {
                        HighlightedImage(image: image, boxes: text.highlights(for: terms)).padding(18)
                        Theme.divider.frame(width: 1)
                        ImageTextPanel(text: text, terms: terms).frame(width: 320)
                    }
                } else {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(18)
                }
            } else {
                EmptyStateView(symbol: "photo", title: "Image not found", message: "The image file is missing from the storage folder.")
            }
        } else if let format, format == .csv || format == .tsv, let preview = PreviewContent.make(for: clip, limit: nil),
                  case .table(let rows) = preview.body {
            DataTableView(rows: rows, maxColumns: 40).padding(12)
        } else {
            let text = clip.text ?? ""
            let shown = formatted ? (format.flatMap { Formatting.pretty(text, format: $0) } ?? text) : text
            let rules = SyntaxHighlighter.ruleSet(kind: clip.kind, format: clip.format)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let wraps = clip.kind != .code && clip.kind != .data
            AttributedTextView(text: SyntaxHighlighter.nsAttributed(shown, ruleSet: rules, font: wraps ? .systemFont(ofSize: 14) : font),
                               wraps: wraps)
        }
    }
}

/// The large preview window. Esc closes it. The panel stays open behind it.
///
/// Like the panel, it is a non-activating panel: Clipboard is never the active app, and an
/// ordinary window of an inactive app cannot take the keyboard, so it stayed behind the panel.
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private final class PreviewPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private var window: PreviewPanel?
    var onClose: (() -> Void)?

    var isOpen: Bool { window?.isVisible == true }
    var isKey: Bool { window?.isKeyWindow == true }

    func show(clip: Clip, image: NSImage?, terms: [String] = [], appearance: PanelAppearance, near frame: NSRect?, actionTitle: String,
              copy: @escaping () -> Void) {
        close()
        let size = NSSize(width: 900, height: 640)
        let panel = PreviewPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = clip.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 480, height: 320)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.appearance = appearance.nsAppearance

        let effect = NSVisualEffectView()
        effect.material = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .hudWindow : .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: LargePreviewView(clip: clip, image: image, terms: terms, actionTitle: actionTitle, copy: copy))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        if let frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        } else {
            panel.center()
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
            onClose?()
        }
    }
}
