import Combine
import Foundation
import Sparkle
import SwiftUI

struct CheckForUpdatesView: View {
    var softwareUpdater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…", action: softwareUpdater.checkForUpdates)
            .disabled(!softwareUpdater.canCheckForUpdates)
    }
}

@Observable
@MainActor
final class SoftwareUpdater: NSObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    var canCheckForUpdates = false
    var lastUpdateCheckDate: Date?
    var automaticallyChecksForUpdates: Bool = true {
        didSet {
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    var automaticallyDownloadsUpdates: Bool = false {
        didSet {
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    var updater: SPUUpdater {
        updaterController.updater
    }

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)

        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.lastUpdateCheckDate = value
            }
            .store(in: &cancellables)

        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        updater.checkForUpdatesInBackground()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://raw.githubusercontent.com/sapoepsilon/Whispera/main/appcast.xml"
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return Set()
    }
}
