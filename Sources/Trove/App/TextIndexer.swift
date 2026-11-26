import Foundation
import OSLog

/// Reads the text in images in the background, one image at a time, newest first: new images
/// right after they are saved, older ones after launch. Where it stopped is in the database
/// (images without recognized text), so it continues after a restart.
@MainActor
final class TextIndexer {
    private weak var app: AppModel?
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "text-indexer")
    /// A pause between images, so a large first run does not keep the Mac busy.
    static let pause: Duration = .milliseconds(150)

    init(app: AppModel) {
        self.app = app
    }

    var isRunning: Bool { task != nil }

    /// Starts reading, unless it is already running or turned off.
    func start() {
        guard task == nil, let app, app.settings.recognizeText, app.store != nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var read = 0
        while !Task.isCancelled {
            guard let app, app.settings.recognizeText, let store = app.store,
                  let batch = try? store.imagesAwaitingRecognition(limit: 10), !batch.isEmpty else { break }
            for clip in batch {
                guard !Task.isCancelled, let id = clip.id else { return }
                // Decrypting is quick; Vision runs off the main thread.
                let data = store.imageData(for: clip)
                let text = await Task.detached(priority: .utility) {
                    data.flatMap(TextRecognizer.recognize)
                }.value
                guard !Task.isCancelled, app.store === store else { return }
                // An image Vision cannot read is marked empty, so it is not tried again and again.
                do {
                    try store.setRecognizedText(id: id, text)
                } catch {
                    log.error("Saving recognized text failed: \(error.localizedDescription, privacy: .public)")
                    return // Otherwise the same image would come back in the next batch.
                }
                app.recognitionDidUpdate(id: id)
                read += 1
                try? await Task.sleep(for: Self.pause)
            }
        }
        if read > 0 { log.info("Read the text in \(read, privacy: .public) images") }
    }
}
