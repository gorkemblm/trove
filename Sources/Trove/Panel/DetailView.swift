import AppKit
import SwiftUI

/// Preview of the selected clip and its metadata table.
///
/// Layout stability rules:
/// - The information table has a fixed height for the largest row set, so the preview area
///   and the "Information" header never move between items.
/// - Each kind always shows the same rows; the only optional row ("Copied from") comes last.
/// - Numbers use tabular digits, so values do not change width as digits change.
struct DetailView: View {
    @ObservedObject var model: PanelModel

    static let rowHeight: CGFloat = 27
    static let maxRows = 9

    var body: some View {
        if model.hasGroupSelection {
            GroupSelectionView(model: model)
        } else if let clip = model.detail {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    // A named hidden item shows its name first, where the eye looks.
                    if clip.kind == .secret, let name = clip.format {
                        HStack(spacing: 8) {
                            Image(systemName: "tag.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                            Text(verbatim: name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        }
                        .padding(.trailing, 76) // Room for the buttons.
                    }
                    preview(clip)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 6) {
                            if model.preview?.formatted == true { FormattedBadge() }
                            if model.imageText != nil { ImageTextBadge(copy: model.copyImageText) }
                            if model.canRenameSelected {
                                PreviewButton(symbol: "pencil", help: L("Name this hidden item (⌘R)"), action: model.requestRename)
                            }
                            if model.canMoveBackSelected {
                                PreviewButton(symbol: "lock.open", help: L("Move back to history (⌘⇧H)"), action: model.moveBackSelected)
                            } else if model.canHideSelected {
                                PreviewButton(symbol: "lock", help: L("Move to Hidden (⌘⇧H)"), action: model.requestHideToggle)
                            }
                            if model.canOpenLargePreview { PreviewButton(action: model.openLargePreview) }
                        }
                    }
                Text("Information")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .frame(height: 20, alignment: .bottomLeading)
                    .padding(.top, 14)
                    .padding(.bottom, 2)
                VStack(spacing: 0) {
                    ForEach(InfoRow.rows(for: clip)) { row in
                        InfoRowView(row: row)
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(Self.maxRows), alignment: .top)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func preview(_ clip: Clip) -> some View {
        switch clip.kind {
        case .text:
            ScrollView {
                Text(String((clip.text ?? "").prefix(Clip.searchCharacters)))
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 40) // Room for the preview button.
            }
        case .code, .data:
            switch model.preview?.body {
            case .table(let rows):
                DataTableView(rows: rows)
            case .text(let attributed):
                ScrollView {
                    Text(attributed)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 40) // Room for the preview button.
                }
            case nil:
                Color.clear
            }
        case .email, .phone:
            VStack(alignment: .leading, spacing: 8) {
                Text(clip.kind == .email ? clip.title : (clip.text ?? ""))
                    .font(.system(size: 17, weight: .medium))
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                Text(clip.text ?? "")
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .lineLimit(6)
                if let domain = clip.domain {
                    Label(domain, systemImage: "globe").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        case .color:
            VStack(alignment: .leading, spacing: 10) {
                if let rgba = clip.rgba {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255).opacity(rgba.a))
                        .frame(minHeight: 40, maxHeight: 110) // Gives way, so the preview never pushes the table.
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
                }
                Text(clip.text ?? "").font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                if let rgba = clip.rgba {
                    // Click a form to copy (or paste) the colour in it.
                    HStack(spacing: 8) {
                        ForEach(rgba.formats, id: \.name) { format in
                            Button { model.copyColor(format.value, format: format.name) } label: {
                                // The values are in the table below; the chip names the form.
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                    Text(verbatim: format.name).font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Theme.kbdFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .help(String(localized: "Copy as \(format.name)") + ": " + format.value)
                        }
                    }
                }
            }
        case .image:
            if let image = model.image(for: clip) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                EmptyStateView(symbol: "photo", title: "Image not found", message: "The image file is missing from the storage folder.")
            }
        case .secret:
            if let text = model.revealedText {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if model.revealFailed {
                EmptyStateView(symbol: "lock.trianglebadge.exclamationmark", title: "This item cannot be opened",
                               message: "It was sealed on another Mac, or this Mac’s hidden key was removed.")
            } else {
                EmptyStateView(symbol: "lock.fill", title: "Locked", message: "Unlock Hidden to see this item.")
            }
        case .file:
            if clip.imageFile != nil, let image = model.image(for: clip) {
                // A copied image file: its picture, with the file name under it.
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(verbatim: clip.filePaths.count > 1
                         ? String(localized: "\(StorageLocation.displayPath(URL(fileURLWithPath: clip.filePaths[0]))) and \((clip.filePaths.count - 1).formatted()) more")
                         : StorageLocation.displayPath(URL(fileURLWithPath: clip.filePaths.first ?? "")))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(clip.filePaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            Text(StorageLocation.displayPath(URL(fileURLWithPath: path)))
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }
    }
}

struct InfoRowView: View {
    let row: InfoRow

    var body: some View {
        HStack(spacing: 12) {
            Text(row.label)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(row.value)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 12.5))
        .frame(height: DetailView.rowHeight)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }
}

struct InfoRow: Identifiable {
    let label: String
    let value: String
    var icon: NSImage?
    var id: String { label }

    static let missing = "—"

    /// Every kind has a fixed row list. "Copied from" is the only optional row and comes last,
    /// so no other row moves when it appears.
    @MainActor
    static func rows(for clip: Clip) -> [InfoRow] {
        var rows: [InfoRow] = [
            InfoRow(label: L("Source"), value: clip.sourceAppName ?? L("Unknown"), icon: AppIcons.icon(for: clip.sourceBundleID)),
            InfoRow(label: L("Content type"), value: clip.kind.title),
        ]

        switch clip.kind {
        case .text:
            rows.append(InfoRow(label: L("Characters"), value: clip.characterCount.formatted()))
            rows.append(InfoRow(label: L("Words"), value: clip.wordCount.formatted()))
            rows.append(InfoRow(label: L("Lines"), value: clip.lineCount.formatted()))
        case .link:
            rows.append(InfoRow(label: L("Domain"), value: clip.domain ?? missing))
        case .image:
            let size = clip.imageWidth.flatMap { w in clip.imageHeight.map { "\(w) × \($0)" } }
            rows.append(InfoRow(label: L("Dimensions"), value: size ?? missing))
            rows.append(InfoRow(label: L("File size"), value: Formatters.bytes(clip.byteSize)))
            rows.append(InfoRow(label: L("Format"), value: "PNG"))
        case .file:
            rows.append(InfoRow(label: L("Files"), value: clip.filePaths.count.formatted()))
            rows.append(InfoRow(label: L("Size"), value: clip.fileSize.map(Formatters.bytes) ?? missing))
        case .color:
            rows.append(InfoRow(label: L("HEX"), value: clip.rgba?.hex ?? missing))
            rows.append(InfoRow(label: L("RGB"), value: clip.rgba?.rgbString ?? missing))
            rows.append(InfoRow(label: L("HSL"), value: clip.rgba?.hslString ?? missing))
        case .data:
            rows.append(InfoRow(label: L("Format"), value: clip.format.map(L) ?? missing))
            rows.append(InfoRow(label: L("Characters"), value: clip.characterCount.formatted()))
            rows.append(InfoRow(label: L("Lines"), value: clip.lineCount.formatted()))
        case .code:
            rows.append(InfoRow(label: L("Language"), value: L(clip.format ?? ContentDetector.language(of: clip.text ?? ""))))
            rows.append(InfoRow(label: L("Characters"), value: clip.characterCount.formatted()))
            rows.append(InfoRow(label: L("Lines"), value: clip.lineCount.formatted()))
        case .email:
            let addresses = ContentDetector.emailAddresses(in: clip.text ?? "") ?? []
            rows.append(InfoRow(label: L("Addresses"), value: addresses.count.formatted()))
            let domains = Set(addresses.compactMap { $0.split(separator: "@").last.map(String.init) })
            rows.append(InfoRow(label: L("Domain"), value: domains.count == 1 ? domains.first! : (domains.isEmpty ? missing : String(localized: "\(domains.count.formatted()) domains"))))
        case .phone:
            rows.append(InfoRow(label: L("Number"), value: ContentDetector.phoneNumber(in: clip.text ?? "") ?? missing))
        case .secret:
            rows.append(InfoRow(label: L("Detected as"), value: clip.secretReason.map(L) ?? missing))
            rows.append(InfoRow(label: L("Characters"), value: clip.characterCount.formatted()))
        }

        rows.append(InfoRow(label: L("Times copied"), value: clip.timesCopied.formatted()))
        rows.append(InfoRow(label: L("First copied"), value: Formatters.fullDate(clip.firstCopiedAt)))
        rows.append(InfoRow(label: L("Last copied"), value: Formatters.fullDate(clip.lastCopiedAt)))
        // Optional rows come last, so no other row moves when they appear.
        if clip.kind == .image, let path = clip.revealPaths.first {
            rows.append(InfoRow(label: L("File"), value: (path as NSString).lastPathComponent))
        }
        if let expiresAt = clip.expiresAt {
            rows.append(InfoRow(label: L("Deletes"), value: Formatters.fullDate(expiresAt)))
        }
        if let host = clip.sourceHost {
            rows.append(InfoRow(label: L("Copied from"), value: host))
        }
        return rows
    }
}

/// The right side while several items are picked: what is picked, and what can be done with it.
struct GroupSelectionView: View {
    @ObservedObject var model: PanelModel

    private static let shown = 8

    var body: some View {
        let clips = model.pickedClips
        VStack(alignment: .leading, spacing: 14) {
            Text("\(clips.count.formatted()) items selected")
                .font(.system(size: 17, weight: .semibold))
            Text(verbatim: Self.summary(of: clips))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 10), count: 4), alignment: .leading, spacing: 10) {
                ForEach(clips.prefix(Self.shown)) { clip in
                    tile(clip)
                }
            }
            if clips.count > Self.shown {
                Text("and \((clips.count - Self.shown).formatted()) more")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                hint("hand.draw", Text("Drag them to another app or to a Finder folder."))
                hint("return", model.returnPastes ? Text("Press ↵ to paste them all.") : Text("Press ↵ to copy them all."))
                hint("xmark.circle", Text("Press Esc to stop selecting."))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hint(_ symbol: String, _ text: Text) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.faint)
            text
        }
    }

    @ViewBuilder private func tile(_ clip: Clip) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.iconFill)
            if clip.kind == .image, let image = model.image(for: clip) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 88, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    ClipIcon(clip: clip, size: 24)
                    Text(verbatim: clip.title)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                }
            }
        }
        .frame(width: 88, height: 66)
    }

    /// "Image × 3 · Text × 2": the kinds in the group, most common first.
    static func summary(of clips: [Clip]) -> String {
        var counts: [ClipKind: Int] = [:]
        for clip in clips { counts[clip.kind, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.title) × \($0.value.formatted())" }
            .joined(separator: " · ")
    }
}
