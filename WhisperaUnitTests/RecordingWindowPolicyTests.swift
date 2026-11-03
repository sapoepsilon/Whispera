import Foundation
import Testing

@testable import Whispera

struct RecordingWindowPolicyTests {

	// The listening pill is the persistent home for recording/transcribing
	// status in both modes now — see WHI-58's presentation pass — so its
	// visibility depends only on whether a session is active, not on mode.
	@Test(arguments: [AudioState.initializing, .recording, .transcribing])
	func anyActiveStateShowsTheListeningPill(state: AudioState) {
		#expect(RecordingWindowPolicy.shouldShowListeningWindow(state: state))
	}

	@Test func idleHidesTheListeningPill() {
		#expect(!RecordingWindowPolicy.shouldShowListeningWindow(state: .idle))
	}

	@Test func textModeNeverShowsLiveTranscriptionWindow() {
		#expect(
			!RecordingWindowPolicy.shouldShowLiveTranscriptionWindow(
				mode: .text, transcriberWantsWindow: true),
			"Text mode has no live words to show; only live mode overlays the pill with them"
		)
	}

	@Test func liveModeShowsLiveTranscriptionWindowOnlyWhenTranscriberWantsIt() {
		#expect(
			RecordingWindowPolicy.shouldShowLiveTranscriptionWindow(
				mode: .liveTranscription, transcriberWantsWindow: true))
		#expect(
			!RecordingWindowPolicy.shouldShowLiveTranscriptionWindow(
				mode: .liveTranscription, transcriberWantsWindow: false))
	}
}

struct InitialDefaultsTests {

	private func isolatedDefaults(_ label: String) -> (UserDefaults, String) {
		let suiteName = "InitialDefaultsTests-\(label)-\(UUID().uuidString)"
		return (UserDefaults(suiteName: suiteName)!, suiteName)
	}

	@Test func freshInstallRegistersEnableStreamingMatchingAudioManagerDefault() {
		let (defaults, suiteName) = isolatedDefaults("fresh")
		defer { defaults.removePersistentDomain(forName: suiteName) }

		AppDelegate.registerInitialDefaults(in: defaults)

		#expect(
			defaults.object(forKey: "enableStreaming") != nil,
			"Fresh installs must resolve enableStreaming so every window reads the same mode"
		)
		#expect(defaults.bool(forKey: "enableStreaming") == Constants.enableStreamingDefault)
	}

	@Test func existingEnableStreamingChoiceIsPreserved() {
		let (defaults, suiteName) = isolatedDefaults("existing")
		defer { defaults.removePersistentDomain(forName: suiteName) }

		defaults.set(false, forKey: "enableStreaming")
		AppDelegate.registerInitialDefaults(in: defaults)

		#expect(defaults.bool(forKey: "enableStreaming") == false)
	}
}
