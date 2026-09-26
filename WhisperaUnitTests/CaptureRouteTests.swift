import Foundation
import Testing

@testable import Whispera

struct CaptureRouteTests {
	@Test func liveModeWithAWhisperModelUsesTheLiveRoute() {
		#expect(
			CaptureRoute.resolve(
				liveTranscriptionEnabled: true, modelSupportsLive: true, useStreamingTranscription: true) == .live)
	}

	@Test func parakeetRecordsThroughTheStreamEvenInLiveMode() {
		#expect(
			CaptureRoute.resolve(
				liveTranscriptionEnabled: true, modelSupportsLive: false, useStreamingTranscription: true)
				== .stream)
		#expect(
			CaptureRoute.resolve(
				liveTranscriptionEnabled: true, modelSupportsLive: false, useStreamingTranscription: false)
				== .file)
	}

	@Test func textModeFollowsTheStreamingSetting() {
		#expect(
			CaptureRoute.resolve(
				liveTranscriptionEnabled: false, modelSupportsLive: true, useStreamingTranscription: true)
				== .stream)
		#expect(
			CaptureRoute.resolve(
				liveTranscriptionEnabled: false, modelSupportsLive: true, useStreamingTranscription: false)
				== .file)
	}

	@Test func onlyTheStreamRouteCanKeepTheMicrophoneOpen() {
		#expect(CaptureRoute.stream.canKeepMicrophoneOpen)
		#expect(!CaptureRoute.live.canKeepMicrophoneOpen)
		#expect(!CaptureRoute.file.canKeepMicrophoneOpen)
	}

	/// The default install is Live Transcription Mode with a Whisper model, so the kept-open
	/// policies must say in the row that they do nothing there.
	@Test(arguments: [MicStreamPolicy.lazyClose, .alwaysOn])
	func keptOpenPoliciesExplainThatTheyDoNothingInLiveMode(policy: MicStreamPolicy) {
		let defaultRoute = CaptureRoute.resolve(
			liveTranscriptionEnabled: Constants.enableStreamingDefault, modelSupportsLive: true,
			useStreamingTranscription: true)
		#expect(defaultRoute == .live)
		let reason = policy.inactiveReason(on: .live)
		#expect(reason?.contains("No effect") == true)
		#expect(policy.settingsDescription(on: .live) == reason)
		#expect(policy.inactiveReason(on: .file)?.contains("No effect") == true)
	}

	@Test(arguments: MicStreamPolicy.allCases)
	func policiesApplyOnTheStreamRoute(policy: MicStreamPolicy) {
		#expect(policy.inactiveReason(on: .stream) == nil)
		#expect(policy.settingsDescription(on: .stream) == policy.summary)
	}

	@Test(arguments: [CaptureRoute.live, .stream, .file])
	func openPerRecordingIsNeverFlagged(route: CaptureRoute) {
		#expect(MicStreamPolicy.onDemand.inactiveReason(on: route) == nil)
	}
}
