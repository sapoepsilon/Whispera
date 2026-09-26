import Foundation
import Testing

@testable import Whispera

struct MicStreamPolicySettingsTests {
	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "MicStreamPolicySettingsTests.\(UUID().uuidString)")!
	}

	@Test func defaultsToOpeningPerRecording() {
		let settings = RecordingControlSettings(defaults: makeDefaults())
		#expect(settings.micStreamPolicy == .onDemand)
		#expect(
			settings.lazyStreamCloseDelay == TimeInterval(RecordingControlSettings.defaultLazyStreamCloseSeconds))
	}

	@Test(arguments: MicStreamPolicy.allCases)
	func readsStoredPolicy(policy: MicStreamPolicy) {
		let defaults = makeDefaults()
		defaults.set(policy.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)
		#expect(RecordingControlSettings(defaults: defaults).micStreamPolicy == policy)
	}

	@Test func unknownPolicyFallsBackToOnDemand() {
		let defaults = makeDefaults()
		defaults.set("sometimes", forKey: RecordingControlSettings.Key.micStreamPolicy)
		#expect(RecordingControlSettings(defaults: defaults).micStreamPolicy == .onDemand)
	}

	@Test func lazyCloseDelayIsClamped() {
		let defaults = makeDefaults()
		defaults.set(0, forKey: RecordingControlSettings.Key.lazyStreamCloseSeconds)
		#expect(RecordingControlSettings(defaults: defaults).lazyStreamCloseDelay == 1)
		defaults.set(5, forKey: RecordingControlSettings.Key.lazyStreamCloseSeconds)
		#expect(RecordingControlSettings(defaults: defaults).lazyStreamCloseDelay == 5)
		defaults.set(10_000, forKey: RecordingControlSettings.Key.lazyStreamCloseSeconds)
		#expect(RecordingControlSettings(defaults: defaults).lazyStreamCloseDelay == 300)
	}

	@Test func lazyCloseOptionsIncludeDefault() {
		#expect(
			RecordingControlSettings.lazyStreamCloseOptions.contains(
				RecordingControlSettings.defaultLazyStreamCloseSeconds))
	}
}

@MainActor
struct AudioEngineControllerStateTests {
	@Test func freshControllerReportsNoRunningEngine() {
		let controller = AudioEngineController()
		#expect(!controller.isRunning)
		#expect(!controller.isEngineRunning)
		controller.cleanup()
		#expect(!controller.isEngineRunning)
	}
}
