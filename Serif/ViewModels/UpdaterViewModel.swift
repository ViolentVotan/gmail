import SwiftUI
private import Sparkle
import Combine
import Observation

@Observable
@MainActor
final class UpdaterViewModel {
    @ObservationIgnored private let updaterController: SPUStandardUpdaterController
    @ObservationIgnored private var cancellable: AnyCancellable?

    var canCheckForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        cancellable = updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
