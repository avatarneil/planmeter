import Combine
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    let updaterController: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false
    private var observation: AnyCancellable?

    init() {
        // `swift run PlanMeter` does not have the app bundle metadata Sparkle
        // requires. Keep that development path usable without a setup alert.
        let isBundledApplication = Bundle.main.bundleURL.pathExtension == "app"
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isBundledApplication,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observation = updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
