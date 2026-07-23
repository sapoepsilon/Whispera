import Foundation
import Testing

@testable import Whispera

struct RecordingWindowPolicyTests {

	@Test(arguments: [AudioState.initializing, .recording, .transcribing])
	func liveModeNeverShowsLegacyListeningWindow(state: AudioState) {
		#expect(
			!RecordingWindowPolicy.shouldShowListeningWindow(state: state, mode: .liveTranscription),
			"Live mode renders its own listening surface inside the live transcription window; showing the legacy window too duplicates it"
		)
	}

	@Test(arguments: [AudioState.initializing, .recording, .transcribing])
	func textModeShowsLegacyListeningWindow(state: AudioState) {
		#expect(RecordingWindowPolicy.shouldShowListeningWindow(state: state, mode: .text))
	}

	@Test(arguments: [RecordingMode.text, .liveTranscription])
	func idleHidesLegacyListeningWindow(mode: RecordingMode) {
		#expect(!RecordingWindowPolicy.shouldShowListeningWindow(state: .idle, mode: mode))
	}

	@Test func textModeNeverShowsLiveTranscriptionWindow() {
		#expect(
			!RecordingWindowPolicy.shouldShowLiveTranscriptionWindow(
				mode: .text, transcriberWantsWindow: true),
			"Text mode renders the legacy listening window; the live window showing too duplicates it"
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
