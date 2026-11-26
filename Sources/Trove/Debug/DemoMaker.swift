#if SNAPSHOTS
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `make demos`: renders the "How Trove Works" animations from the real panel with sample data.
/// Each frame shows a caption with the keys being pressed, so the demos teach the shortcuts.
@MainActor
enum DemoMaker {
    struct Frame {
        let image: NSBitmapImageRep
        let seconds: Double
    }

    /// GIF width in pixels: sharp enough on a Retina onboarding window, small enough to bundle.
    static let width = 980

    static func run(outputDirectory: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for demo in Demo.allCases {
                let (app, model, clips) = try SnapshotRunner.makeScene(manyItems: false)
                _ = app
                let frames = try frames(for: demo, model: model, clips: clips)
                let url = outputDirectory.appendingPathComponent("\(demo.rawValue).gif")
                try writeGIF(frames, to: url)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                print("Demo \(demo.rawValue): \(frames.count) frames, \(size / 1024) KB")
            }
            return 0
        } catch {
            print("Demos failed: \(error)")
            return 2
        }
    }

    // MARK: - Scripts

    private static func frames(for demo: Demo, model: PanelModel, clips: [String: Clip]) throws -> [Frame] {
        var frames: [Frame] = []
        func shot(_ keys: [String], _ text: String, _ seconds: Double = 1.1) {
            let caption = AnyView(Caption(keys: keys, text: text))
            frames.append(Frame(image: SnapshotRunner.render(model, overlay: caption), seconds: seconds))
        }
        func type(_ text: String, keys: [String] = [], caption: String, from start: Int = 1) {
            for end in start...text.count {
                model.query = String(text.prefix(end))
                shot(keys.isEmpty ? [String(text.prefix(end).last ?? " ")] : keys, caption, end == text.count ? 1.0 : 0.22)
            }
        }

        switch demo {
        case .browse:
            model.selectedID = model.clips.first?.id
            shot(["⌥", "Space"], L("Open Trove over any app"), 1.4)
            for clip in model.clips.dropFirst().prefix(3) {
                model.selectedID = clip.id
                shot(["↓"], L("Choose an item"), 0.7)
            }
            type("github", caption: L("Type to search everything"))
            shot(["↵"], L("Pastes it into the app you were in"), 1.6)

        case .groups:
            shot([], L("Type / to jump to a group"), 1.0)
            type("/ima", caption: L("The groups that match"))
            model.chooseGroupSuggestion()
            shot(["↵"], L("The group opens and stays as a chip"), 1.6)
            shot(["⌫"], L("In an empty search: back to All"), 1.3)

        case .apps:
            shot([], L("Type @ for the apps you copied in"), 1.0)
            type("@ar", caption: L("The apps that match, most used first"))
            model.chooseAppSuggestion()
            shot(["↵"], L("Only what you copied in Arc"), 1.3)
            type("grdb", caption: L("…and search inside it"))

        case .actions:
            model.selectedID = clips["screenshot"]?.id
            shot([], L("Select an item"), 1.0)
            model.toggleActions()
            shot(["⌘", "K"], L("Everything you can do with it"), 1.8)
            for (end, text) in ["c", "co", "cop"].enumerated() {
                model.actionFilter = text
                shot([String(text.last!)], L("Type to filter the actions"), end == 2 ? 1.4 : 0.25)
            }
            model.closeActions()
            shot(["esc"], L("Every action also has its own shortcut"), 1.2)

        case .editor:
            model.selectedID = clips["json"]?.id
            shot([], L("A one-line JSON from the terminal"), 1.2)
            model.requestEdit()
            shot(["⌘", "E"], L("Edit it right here"), 1.4)
            model.apply(.jsonPretty)
            shot(["JSON", "›", L("Format JSON")], L("Transforms in the menus above"), 1.8)
            shot(["⌘", "↵"], L("Pastes the result · Esc cancels"), 1.6)
            model.cancelEdit()

        case .textInImages:
            model.selectedID = clips["screenshot"]?.id
            shot([], L("A screenshot of an invoice"), 1.2)
            type("paid", caption: L("Search for a word that is only in the image"))
            shot(["⌘", "⇧", "C"], L("The word is boxed; this copies its line"), 2.0)

        case .snippets:
            model.selectedID = clips["email"]?.id
            shot([], L("Something you paste often"), 1.0)
            model.requestSaveSnippet()
            shot(["⌘", "S"], L("Keep it as a snippet"), 1.2)
            for end in 1...10 {
                model.naming?.name = String("Work email".prefix(end))
                shot([], L("Give it a name"), end == 10 ? 1.0 : 0.15)
            }
            model.confirmNaming()
            model.category = .snippets
            shot(["↵"], L("Kept for good, found by its name"), 1.8)
            model.category = .all

        case .selectAndDrag:
            model.selectedID = model.clips.first?.id
            shot([], L("Several items at once"), 1.0)
            for name in ["link", "email", "code"] {
                if let clip = clips[name] { model.togglePick(clip) }
                shot(["⌘", L("click")], L("Picks items · ⇧-click picks a range"), 0.7)
            }
            shot(["↵"], L("Pastes them all · or drag them to any app"), 2.0)
            model.endSelecting()
        }
        return frames
    }

    // MARK: - GIF

    private static func writeGIF(_ frames: [Frame], to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for frame in frames {
            guard let image = scaled(frame.image) else { continue }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.seconds],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func scaled(_ rep: NSBitmapImageRep) -> CGImage? {
        guard let source = rep.cgImage else { return nil }
        let height = Int(Double(width) * Double(source.height) / Double(source.width))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// The caption at the bottom of a demo frame: the keys, then what they do.
private struct Caption: View {
    let keys: [String]
    let text: String

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                if !keys.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                            Text(verbatim: key)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .frame(minWidth: 28, minHeight: 28)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
                Text(verbatim: text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Color.black.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .padding(.bottom, 58)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
