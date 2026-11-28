import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Content read from the pasteboard, ready to store.
struct CapturedContent: Sendable {
    var kind: ClipKind
    var text: String? = nil
    var rtf: Data? = nil
    var imageData: Data? = nil
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
    var fileSize: Int? = nil
    /// Code: language. Data: format name.
    var format: String? = nil
    var byteSize: Int
    var hash: String
}

struct ClipSource: Sendable {
    var bundleID: String?
    var appName: String?
    var url: String?
}

enum ClipClassifier {
    static let maxTextBytes = 5 * 1_048_576
    static let maxRTFBytes = 1_048_576

    /// Reads the pasteboard and decides what kind of clip it holds.
    /// Order: files, then images (when no real text comes with them), then text, links and colours.
    @MainActor
    static func capture(from pasteboard: NSPasteboard, maxImageBytes: Int) -> CapturedContent? {
        let types = pasteboard.types ?? []

        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path).joined(separator: "\n")
            let size = urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            var content = CapturedContent(
                kind: .file, text: paths, fileSize: size > 0 ? size : nil,
                byteSize: paths.utf8.count, hash: hash("file", paths)
            )
            // Image files also belong in Images, with a preview. macOS lets this app read a copied
            // file only now, so the preview is made at once and stored encrypted like any image.
            if Clip.areImageFiles(urls.map(\.path)) {
                content.format = Clip.imageFilesFormat
                if let preview = imagePreview(of: urls[0]) {
                    content.imageData = preview.png
                    content.imageWidth = preview.width
                    content.imageHeight = preview.height
                    content.byteSize += preview.png.count
                }
            }
            return content
        }

        let string = pasteboard.string(forType: .string)
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasRichText = types.contains(.rtf) || types.contains(.rtfd)
        let hasImage = types.contains(.png) || types.contains(.tiff)

        // Browsers put the image URL next to a copied image; documents put text next to an image.
        if hasImage, trimmed.isEmpty || (!hasRichText && isLink(trimmed)) {
            if let image = imageContent(from: pasteboard, maxBytes: maxImageBytes) { return image }
            if trimmed.isEmpty { return nil }
        }

        guard let string, !trimmed.isEmpty, string.utf8.count <= maxTextBytes else { return nil }
        return textContent(string, rtf: types.contains(.rtf) ? pasteboard.data(forType: .rtf) : nil)
    }

    static func textContent(_ string: String, rtf: Data?) -> CapturedContent {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = textKind(of: string)
        // Text, code and data keep their exact layout (indentation); the other kinds are single values.
        let keepsLayout = kind == .text || kind == .code || kind == .data
        let value = keepsLayout ? string : trimmed
        let rich = keepsLayout ? rtf.flatMap { $0.count <= maxRTFBytes ? $0 : nil } : nil
        let format: String? = switch kind {
        case .data: ContentDetector.dataFormat(of: string)?.rawValue
        case .code: ContentDetector.language(of: string)
        default: nil
        }
        return CapturedContent(
            kind: kind, text: value, rtf: rich, format: format,
            byteSize: value.utf8.count + (rich?.count ?? 0), hash: hash(kind.rawValue, value)
        )
    }

    private static func imageContent(from pasteboard: NSPasteboard, maxBytes: Int) -> CapturedContent? {
        var data = pasteboard.data(forType: .png)
        if data == nil, let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }
        return imageContent(data: data, maxBytes: maxBytes)
    }

    /// An image clip from PNG data, or from another image format converted to PNG
    /// (the copy path writes PNG). Nil when the data is not an image or is too large.
    static func imageContent(data: Data, maxBytes: Int) -> CapturedContent? {
        guard data.count <= maxBytes, let rep = NSBitmapImageRep(data: data) else { return nil }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let png = isPNG ? data : rep.representation(using: .png, properties: [:]), png.count <= maxBytes else { return nil }
        return CapturedContent(
            kind: .image, imageData: png, imageWidth: rep.pixelsWide, imageHeight: rep.pixelsHigh,
            byteSize: png.count, hash: hash("image", png)
        )
    }

    /// A preview of an image file: at most 1600 pixels on the long side, as PNG, with the size
    /// of the original. Nil when the file cannot be read or is larger than 100 MB.
    static func imagePreview(of url: URL, maxPixels: Int = 1600) -> (png: Data, width: Int, height: Int)? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 100 * 1_048_576, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return (png, width, height)
    }

    /// Link, IP address, colour, e-mail, phone, data, code or plain text. The whole text must be of the kind.
    static func textKind(of string: String) -> ClipKind {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLink(trimmed) { return .link }
        // Before phone numbers: Apple's detector reads some IPv4 addresses as numbers.
        if ContentDetector.ipAddresses(in: trimmed) != nil { return .ip }
        if isColor(trimmed) { return .color }
        if ContentDetector.emailAddresses(in: trimmed) != nil { return .email }
        if ContentDetector.phoneNumber(in: trimmed) != nil { return .phone }
        if ContentDetector.dataFormat(of: string) != nil { return .data }
        if ContentDetector.isCode(string) { return .code }
        return .text
    }

    static func isLink(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 4096, !s.contains(where: \.isWhitespace) else { return false }
        if s.lowercased().hasPrefix("www."), s.dropFirst(4).contains(".") { return true }
        guard let components = URLComponents(string: s), let scheme = components.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp"].contains(scheme) && components.host?.isEmpty == false
    }

    static func isColor(_ s: String) -> Bool {
        s.count <= 40 && RGBA(parsing: s) != nil
    }

    static func hash(_ prefix: String, _ string: String) -> String {
        hash(prefix, Data(string.utf8))
    }

    static func hash(_ prefix: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
