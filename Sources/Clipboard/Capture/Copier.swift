import AppKit

/// Writes a stored clip back to the general pasteboard.
@MainActor
enum Copier {
    /// Marks content this app wrote, so the monitor does not record it again.
    static let ownType = NSPasteboard.PasteboardType("com.iokoda.clipboard.own")
    /// nspasteboard.org marker: other clipboard managers do not save this content.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @discardableResult
    static func copy(_ clip: Clip, plainText: Bool, imageData: Data?) -> Bool {
        var items: [NSPasteboardItem] = []

        switch clip.kind {
        case .text, .color, .code, .email, .phone, .data:
            let item = NSPasteboardItem()
            item.setString(clip.text ?? "", forType: .string)
            if !plainText, let rtf = clip.rtf { item.setData(rtf, forType: .rtf) }
            items = [item]

        case .link:
            let item = NSPasteboardItem()
            item.setString(clip.text ?? "", forType: .string)
            if !plainText, let url = clip.linkURL { item.setString(url.absoluteString, forType: .URL) }
            items = [item]

        case .image:
            guard let data = imageData else { return false }
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            // Older apps read only TIFF. Skip it for very large images.
            if data.count < 5 * 1_048_576, let tiff = NSImage(data: data)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            items = [item]

        case .secret:
            // `text` holds the revealed content here, never the masked form.
            let item = NSPasteboardItem()
            item.setString(clip.text ?? "", forType: .string)
            item.setData(Data(), forType: concealedType)
            items = [item]

        case .file:
            if plainText {
                let item = NSPasteboardItem()
                item.setString(clip.text ?? "", forType: .string)
                items = [item]
            } else {
                items = clip.filePaths.map { path in
                    let item = NSPasteboardItem()
                    item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                    return item
                }
            }
        }

        return write(items)
    }

    /// Several items at once. Text-like items alone become one text, one line each, which pastes
    /// well everywhere. A mix keeps one pasteboard item per clip, and images go as files, so they
    /// arrive whole in Finder, Mail and chat apps.
    @discardableResult
    static func copy(group: [(clip: Clip, imageFile: URL?)], plainText: Bool) -> Bool {
        let clips = group.map(\.clip).filter { $0.kind != .secret }
        if !clips.isEmpty, clips.allSatisfy(\.kind.isTextual) {
            let item = NSPasteboardItem()
            item.setString(clips.map { $0.text ?? "" }.joined(separator: "\n"), forType: .string)
            return write([item])
        }
        return write(group.flatMap { groupItems($0.clip, imageFile: $0.imageFile) })
    }

    /// The pasteboard items of one clip in a group copy or a drag. Images need a file
    /// (the screenshot itself, or a temporary PNG); without one they are left out.
    static func groupItems(_ clip: Clip, imageFile: URL?) -> [NSPasteboardItem] {
        switch clip.kind {
        case .text, .color, .code, .email, .phone, .data:
            let item = NSPasteboardItem()
            item.setString(clip.text ?? "", forType: .string)
            return [item]
        case .link:
            let item = NSPasteboardItem()
            item.setString(clip.text ?? "", forType: .string)
            if let url = clip.linkURL { item.setString(url.absoluteString, forType: .URL) }
            return [item]
        case .image:
            guard let imageFile else { return [] }
            return [fileItem(imageFile)]
        case .file:
            return clip.filePaths.map { fileItem(URL(fileURLWithPath: $0)) }
        case .secret:
            return []
        }
    }

    private static func fileItem(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }

    private static func write(_ items: [NSPasteboardItem]) -> Bool {
        guard let first = items.first else { return false }
        first.setData(Data(), forType: ownType)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }
}
