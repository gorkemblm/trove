import Combine
import Foundation
import Sparkle

/// Updates with Sparkle. Trove itself has no network access: Sparkle's download service, a
/// separate sandboxed process, reads the update list and downloads the update; updates are
/// signed with the project's EdDSA key and notarized. Automatic checks are asked about once
/// (Sparkle's standard prompt, on the second launch) and can be changed in Settings › General.
@MainActor
final class Updates: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    private var observers: Set<AnyCancellable> = []

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observers)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &observers)
    }

    /// Settings, the menu bar menu and the panel's actions.
    func check() {
        controller.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }
}
