import Foundation
import Sparkle
import SwiftUI

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

@MainActor
final class SoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController!

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var lastUpdaterError: String?
    @Published var automaticallyChecksForUpdates: Bool = true {
        didSet {
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var automaticallyDownloadsUpdates: Bool = false {
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
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        do {
            try updaterController.updater.start()
            lastUpdaterError = nil
        } catch {
            lastUpdaterError = error.localizedDescription
            AppLogger.shared.general.error("❌ Sparkle updater failed to start: \(error.localizedDescription)")
        }

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)

        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        lastUpdaterError = nil
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        lastUpdaterError = nil
        updater.checkForUpdatesInBackground()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://raw.githubusercontent.com/sapoepsilon/Whispera/main/appcast.xml"
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return Set()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        // SPUNoUpdateFoundError (domain: SPUNoUpdateFoundError, code: 0) is not a real error
        if nsError.domain == "SPUNoUpdateFoundError" { return }
        lastUpdaterError = error.localizedDescription
        AppLogger.shared.general.error("❌ Sparkle update aborted: \(error.localizedDescription)")
    }
}
