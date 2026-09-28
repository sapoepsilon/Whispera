import Foundation
import Testing

@testable import Whispera

@MainActor
struct MicStreamPolicyMigrationTests {
	private func makeDefaults(_ name: String = #function) -> (UserDefaults, String) {
		let suite = "MicStreamPolicyMigrationTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		// Mirrors the app: registered defaults are present but must not count as a choice
		AppDelegate.registerInitialDefaults(in: defaults)
		return (defaults, suite)
	}

	private func stored(_ defaults: UserDefaults, _ suite: String) -> [String: Any] {
		defaults.persistentDomain(forName: suite) ?? [:]
	}

	@Test func alwaysOnPickedWhileLiveModeWasDefaultIsReverted() {
		let (defaults, suite) = makeDefaults()
		defaults.set(MicStreamPolicy.alwaysOn.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)

		let reverted = MicStreamPolicyMigration.apply(to: defaults, stored: stored(defaults, suite))
		#expect(reverted == .alwaysOn)
		#expect(RecordingControlSettings(defaults: defaults).micStreamPolicy == .onDemand)
		#expect(MicStreamPolicyMigration.pendingNotice(in: defaults) == .alwaysOn)

		let center = AppNoticeCenter(defaults: defaults)
		center.postLaunchNotices()
		#expect(center.notices.contains { $0.kind == .micStreamPolicyReset })
		center.dismiss(.micStreamPolicyReset)
		#expect(MicStreamPolicyMigration.pendingNotice(in: defaults) == nil)

		let relaunch = AppNoticeCenter(defaults: defaults)
		relaunch.postLaunchNotices()
		#expect(!relaunch.notices.contains { $0.kind == .micStreamPolicyReset })
	}

	@Test func runsOnlyOnceSoALaterChoiceIsKept() {
		let (defaults, suite) = makeDefaults()
		MicStreamPolicyMigration.apply(to: defaults, stored: stored(defaults, suite))

		defaults.set(MicStreamPolicy.alwaysOn.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)
		#expect(MicStreamPolicyMigration.apply(to: defaults, stored: stored(defaults, suite)) == nil)
		#expect(RecordingControlSettings(defaults: defaults).micStreamPolicy == .alwaysOn)
	}

	@Test func explicitLiveModeChoiceKeepsThePolicy() {
		for liveMode in [true, false] {
			let (defaults, suite) = makeDefaults("explicit\(liveMode)")
			defaults.set(MicStreamPolicy.lazyClose.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)
			defaults.set(liveMode, forKey: "enableStreaming")
			#expect(MicStreamPolicyMigration.apply(to: defaults, stored: stored(defaults, suite)) == nil)
			#expect(RecordingControlSettings(defaults: defaults).micStreamPolicy == .lazyClose)
		}
	}

	@Test func routesThatNeverKeepTheMicOpenAreLeftAlone() {
		let (fileDefaults, fileSuite) = makeDefaults("file")
		fileDefaults.set(MicStreamPolicy.alwaysOn.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)
		fileDefaults.set(false, forKey: "useStreamingTranscription")
		#expect(MicStreamPolicyMigration.apply(to: fileDefaults, stored: stored(fileDefaults, fileSuite)) == nil)

		let (parakeetDefaults, parakeetSuite) = makeDefaults("parakeet")
		parakeetDefaults.set(
			MicStreamPolicy.alwaysOn.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)
		parakeetDefaults.set(ParakeetModel.allCases[0].rawValue, forKey: "selectedModel")
		#expect(
			MicStreamPolicyMigration.apply(to: parakeetDefaults, stored: stored(parakeetDefaults, parakeetSuite))
				== nil)
		#expect(RecordingControlSettings(defaults: parakeetDefaults).micStreamPolicy == .alwaysOn)
	}

	@Test func onDemandNeedsNoNotice() {
		let (defaults, suite) = makeDefaults()
		defaults.set(MicStreamPolicy.onDemand.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)
		#expect(MicStreamPolicyMigration.apply(to: defaults, stored: stored(defaults, suite)) == nil)
		#expect(MicStreamPolicyMigration.pendingNotice(in: defaults) == nil)
	}
}
