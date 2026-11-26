import AppKit
import OSLog
import SwiftUI

/// One dragged thing: what the drop target receives, and the picture under the pointer.
struct DragItem {
    let pasteboardItem: NSPasteboardItem
    let image: NSImage
}

/// Plain PNG copies of encrypted images, made only when an image is dragged or copied as a file
/// (in a group). They live in the app's own temporary folder, readable only by this user, and
/// are removed after an hour, when Clipboard starts and when it quits. Screenshots need none:
/// their own file is used.
enum ExportFiles {
    static let lifetime: TimeInterval = 3600
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "export-files")

    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exported Images", isDirectory: true)
    }

    /// Writes the image to a new folder (so names never clash) and returns the file.
    static func write(_ data: Data, for clip: Clip) throws -> URL {
        removeExpired()
        let fm = FileManager.default
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(fileName(for: clip))
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// "Image 2026-11-26 at 140322.png", the same name Save Image suggests.
    static func fileName(for clip: Clip) -> String {
        let stamp = clip.lastCopiedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return String(localized: "Image \(stamp).png")
    }

    static func removeExpired(now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if now.timeIntervalSince(created) > lifetime { try? fm.removeItem(at: folder) }
        }
    }

    static func removeAll() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        do {
            try fm.removeItem(at: root)
        } catch {
            log.error("Removing exported images failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum DragPreview {
    static let size: CGFloat = 56

    /// A thumbnail for images, the Finder icon for files, the kind's symbol for the rest.
    static func image(for clip: Clip, file: URL?) -> NSImage {
        if clip.kind == .image, let file, let image = NSImage(contentsOf: file) {
            return thumbnail(image)
        }
        if clip.kind == .file, let path = clip.filePaths.first {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        return symbolTile(clip.kind.symbol)
    }

    private static func thumbnail(_ image: NSImage) -> NSImage {
        let scale = min(size * 1.6 / max(image.size.width, 1), size * 1.6 / max(image.size.height, 1), 1)
        let target = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    private static func symbolTile(_ symbol: String) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let tinted = NSImage(size: glyph.size, flipped: false) { glyphRect in
                    glyph.draw(in: glyphRect)
                    NSColor.labelColor.set()
                    glyphRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
                                       width: glyph.size.width, height: glyph.size.height))
            }
            return true
        }
    }
}

/// Clicks and drags on a list row. SwiftUI gestures give no modifier keys and no multi-item
/// drag from a panel, so the row is covered by this AppKit view.
struct RowMouseArea: NSViewRepresentable {
    /// Modifier keys and click count.
    let onClick: (NSEvent.ModifierFlags, Int) -> Void
    /// The items to drag; empty when the row cannot be dragged.
    let dragItems: () -> [DragItem]
    let onDragStart: () -> Void
    /// True when the items were dropped somewhere.
    let onDragEnd: (Bool) -> Void

    func makeNSView(context: Context) -> RowMouseView {
        let view = RowMouseView()
        update(view)
        return view
    }

    func updateNSView(_ view: RowMouseView, context: Context) {
        update(view)
    }

    private func update(_ view: RowMouseView) {
        view.onClick = onClick
        view.dragItems = dragItems
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
    }
}

final class RowMouseView: NSView, NSDraggingSource {
    var onClick: (NSEvent.ModifierFlags, Int) -> Void = { _, _ in }
    var dragItems: () -> [DragItem] = { [] }
    var onDragStart: () -> Void = {}
    var onDragEnd: (Bool) -> Void = { _ in }

    private var mouseDownEvent: NSEvent?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The list must still scroll under the pointer.
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView { scrollView.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = mouseDownEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        dragging = true
        let items = dragItems()
        guard !items.isEmpty else { NSSound.beep(); return }
        onDragStart()
        let origin = convert(down.locationInWindow, from: nil)
        let dragging = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.pasteboardItem)
            let size = item.image.size
            let offset = CGFloat(min(index, 4)) * 6
            draggingItem.setDraggingFrame(NSRect(x: origin.x - size.width / 2 + offset, y: origin.y - size.height / 2 - offset,
                                                 width: size.width, height: size.height), contents: item.image)
            return draggingItem
        }
        let session = beginDraggingSession(with: dragging, event: down, source: self)
        session.draggingFormation = items.count > 1 ? .pile : .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !dragging else { return }
        onClick(event.modifierFlags.intersection(.deviceIndependentFlagsMask), event.clickCount)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// Outside the panel, the panel fades away so the whole target app is visible and takes the drop.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window else { return }
        let inside = window.frame.contains(screenPoint)
        window.ignoresMouseEvents = !inside
        let alpha: CGFloat = inside ? 1 : 0
        if window.alphaValue != alpha {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = alpha
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let window = window
        dragging = false
        mouseDownEvent = nil
        // First: a drop closes the panel, and it must not flash back before it does.
        onDragEnd(operation != [])
        window?.ignoresMouseEvents = false
        window?.alphaValue = 1
    }
}
