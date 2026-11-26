import Foundation

/// Watches the folder where macOS saves screenshots. A screenshot saved as a file never reaches
/// the clipboard, so the monitor cannot see it; this adds each new image file instead.
///
/// macOS writes a screenshot to a hidden temporary file and then renames it. A change in the
/// folder starts a short wait, then a scan; files present before the watch started are skipped.
@MainActor
final class ScreenshotWatcher {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif"]
    static let settleDelay: TimeInterval = 0.6

    let directory: URL
    private let onNewImage: (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var pendingScan: DispatchWorkItem?

    init(directory: URL, onNewImage: @escaping (URL) -> Void) {
        self.directory = directory
        self.onNewImage = onNewImage
    }

    /// Returns false when the folder cannot be opened.
    @discardableResult
    func start() -> Bool {
        stop()
        known = listing()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        pendingScan?.cancel()
        pendingScan = nil
        source?.cancel()
        source = nil
    }

    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func scan() {
        let current = listing()
        let added = current.subtracting(known)
        known = current
        for name in added.sorted() {
            onNewImage(directory.appendingPathComponent(name))
        }
    }

    private func listing() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { name in
            !name.hasPrefix(".") && Self.imageExtensions.contains((name as NSString).pathExtension.lowercased())
        })
    }
}
