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
    static let shared = SoftwareUpdater()

    private var updaterController: SPUStandardUpdaterController!

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var lastUpdaterError: String?
    @Published var availableUpdateVersion: String?
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

    private override init() {
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
            AppLogger.shared.general.error("Sparkle updater failed to start: \(error.localizedDescription)")
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdateVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else {
            lastUpdaterError = error.localizedDescription
            AppLogger.shared.general.error("Sparkle update aborted: \(error.localizedDescription)")
            return
        }
        // "No update found" and user cancellation are normal outcomes, not errors
        let benignCodes: Set<Int> = [
            Int(SUError.noUpdateError.rawValue),
            Int(SUError.installationCanceledError.rawValue),
            Int(SUError.installationAuthorizeLaterError.rawValue),
        ]
        if benignCodes.contains(nsError.code) { return }
        lastUpdaterError = error.localizedDescription
        AppLogger.shared.general.error("Sparkle update aborted: \(error.localizedDescription)")
    }
}
