import AppKit
import SwiftUI

/// The import window: Settings › Storage › Import… and onboarding open it.
@MainActor
final class ImportWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let flow: ImportFlow

    init(app: AppModel) {
        flow = ImportFlow(app: app)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: ImportView.size),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = L("Import History")
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        let host = NSHostingView(rootView: ImportView(flow: flow, close: {}))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        window.contentView = background
        window.apply(app.settings.panelAppearance, animated: false)
        super.init()
        window.delegate = self
        host.rootView = ImportView(flow: flow) { [weak self] in self?.window.performClose(nil) }
    }

    func apply(_ appearance: PanelAppearance) {
        window.apply(appearance, animated: true)
    }

    func show() {
        if !window.isVisible {
            flow.restart()
            window.center()
        }
        window.showInFront()
    }

    /// While items are being saved, the window stays (closing would leave half an import).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !flow.isBusy
    }
}

struct ImportView: View {
    static let size = NSSize(width: 600, height: 540)

    @ObservedObject var flow: ImportFlow
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import History").font(.system(size: 22, weight: .bold))
                Text("Bring your clipboard history from another app. Nothing is saved until you confirm.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 44)
            .padding(.bottom, 20)
            Group {
                switch flow.step {
                case .choose: chooseStep
                case .password(let source, let url): passwordStep(source, url)
                case .reading(let source, let text): readingStep(source, text)
                case .summary(let plan): summaryStep(plan)
                case .importing(let plan, let progress): importingStep(plan, progress)
                case .done(let source, let result): doneStep(source, result)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.easeInOut(duration: 0.18), value: stepKey)
    }

    /// For the cross-fade between steps.
    private var stepKey: String {
        switch flow.step {
        case .choose: "choose"
        case .password: "password"
        case .reading: "reading"
        case .summary: "summary"
        case .importing: "importing"
        case .done: "done"
        }
    }

    // MARK: Steps

    @State private var showOthers = false

    private var chooseStep: some View {
        let nearby = ImportSource.nearby
        let others = ImportSource.others
        return VStack(alignment: .leading, spacing: 14) {
            sourceList(nearby, iconSize: 38)
            if !others.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showOthers.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showOthers ? 90 : 0))
                        Text("Other sources").font(.system(size: 12.5, weight: .medium))
                        Text(verbatim: others.map(\.title).joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showOthers {
                    sourceList(others, iconSize: 30)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            problemLine
            Spacer(minLength: 0)
            HStack {
                Label("Items you already have are merged, not duplicated.", systemImage: "arrow.triangle.merge")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
    }

    private func sourceList(_ sources: [ImportSource], iconSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                if index > 0 { Divider().padding(.leading, iconSize + 28) }
                Button { flow.choose(source, in: NSApp.keyWindow) } label: {
                    HStack(spacing: 14) {
                        SourceIcon(source: source, size: iconSize)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: source.title).font(.system(size: 14, weight: .semibold))
                            Text(verbatim: source.howTo).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Text("Choose…").font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, iconSize > 32 ? 12 : 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func passwordStep(_ source: ImportSource, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SourceHeader(source: source, title: source == .raycast ? L("Open Raycast Export") : L("Open Encrypted Export"),
                         detail: url.lastPathComponent)
            SecureField(source == .raycast ? L("The password you set when exporting from Raycast") : L("The password this export was made with"),
                        text: $flow.password)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(flow.submitPassword)
            problemLine
            if source == .raycast {
                Label("Raycast keeps images outside its export, so they are not imported.", systemImage: "photo")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back", action: flow.restart).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open", action: flow.submitPassword)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.password.isEmpty)
            }
        }
    }

    private func readingStep(_ source: ImportSource, _ text: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            SourceIcon(source: source, size: 56)
            ProgressView().controlSize(.regular)
            Text(verbatim: text).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryStep(_ plan: ImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SourceHeader(source: plan.source, title: plan.total == 1 ? L("1 item to import") : String(localized: "\(plan.total.formatted()) items to import"),
                         detail: dateRange(plan))
            KindChips(kinds: plan.kinds, secrets: plan.secrets.count)
            VStack(alignment: .leading, spacing: 9) {
                if plan.alreadyHave > 0 {
                    fact("arrow.triangle.merge", String(localized: "\(plan.alreadyHave.formatted()) already in Trove: merged, not duplicated."))
                }
                if !plan.secrets.isEmpty {
                    fact("lock.fill", String(localized: "\(plan.secrets.count.formatted()) look like secrets: they go to Hidden."))
                } else if !plan.secretsToHidden {
                    fact("lock.slash", L("Items that look like secrets are left out (Settings › Privacy)."))
                }
                if plan.skippedImages > 0 {
                    fact("photo", String(localized: "\(plan.skippedImages.formatted()) images stay in \(plan.source.title): they are not in its export."))
                }
            }
            if plan.removedByRetention + plan.removedByItemLimit > 0 {
                LimitWarning(plan: plan, keep: flow.keepEverything)
            }
            problemLine
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", action: flow.restart).keyboardShortcut(.cancelAction)
                Spacer()
                Button(plan.total == 1 ? L("Import 1 Item") : String(localized: "Import \(plan.total.formatted()) Items"), action: flow.startImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.total == 0)
            }
        }
    }

    private func importingStep(_ plan: ImportPlan, _ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SourceHeader(source: plan.source, title: L("Importing…"),
                         detail: String(localized: "\(Int((progress * Double(plan.total)).rounded()).formatted()) of \(plan.total.formatted())"))
            ProgressView(value: progress).progressViewStyle(.linear)
            Text("You can keep working while it runs.").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func doneStep(_ source: ImportSource, _ result: ImportResult) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text("Import finished").font(.system(size: 18, weight: .semibold))
            Text(verbatim: summary(result)).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            HStack {
                Button("Import More…", action: flow.restart)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Pieces

    @ViewBuilder private var problemLine: some View {
        if let problem = flow.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
    }

    private func dateRange(_ plan: ImportPlan) -> String {
        guard let earliest = plan.earliest, let latest = plan.latest else { return plan.source.title }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLocale.current)
        let first = earliest.formatted(style), last = latest.formatted(style)
        return first == last ? first : "\(first) – \(last)"
    }

    private func summary(_ result: ImportResult) -> String {
        var parts = [String(localized: "\(result.added.formatted()) new items")]
        if result.merged > 0 { parts.append(String(localized: "\(result.merged.formatted()) merged")) }
        if result.hidden > 0 { parts.append(String(localized: "\(result.hidden.formatted()) in Hidden")) }
        return parts.joined(separator: " · ")
    }
}

/// The installed app's icon, or Trove's own; a plain symbol when the app is not installed.
struct SourceIcon: View {
    let source: ImportSource
    let size: CGFloat

    var body: some View {
        Group {
            if source == .trove {
                Image(nsImage: NSApp.applicationIconImage).resizable()
            } else if let icon = AppIcons.icon(for: source.bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                // Not installed: a letter tile. Other companies' logos are not bundled with Trove.
                Text(verbatim: String(source.title.prefix(1)))
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(source.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SourceHeader: View {
    let source: ImportSource
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            SourceIcon(source: source, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Text(verbatim: detail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// "3,351 Text · 418 Link · 30 File": what the file holds, by kind.
private struct KindChips: View {
    let kinds: [ClipKind: Int]
    let secrets: Int

    var body: some View {
        let sorted = kinds.sorted { $0.value > $1.value }
        HStack(spacing: 6) {
            ForEach(sorted, id: \.key) { kind, count in chip(kind.symbol, "\(count.formatted()) \(kind.title)") }
            if secrets > 0 { chip("lock.fill", "\(secrets.formatted()) \(ClipKind.secret.title)") }
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(verbatim: text).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// The current limits would remove part of the import: say how much, and offer to keep it.
private struct LimitWarning: View {
    let plan: ImportPlan
    let keep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if plan.removedByRetention > 0 {
                        Text(String(localized: "\(plan.removedByRetention.formatted()) of these are older than your Keep History limit and would be removed the next time Trove cleans up."))
                    }
                    if plan.removedByItemLimit > 0 {
                        Text(String(localized: "Your Maximum Items limit would remove the \(plan.removedByItemLimit.formatted()) oldest items."))
                    }
                }
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                Button("Keep Them: Lift These Limits", action: keep)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}
