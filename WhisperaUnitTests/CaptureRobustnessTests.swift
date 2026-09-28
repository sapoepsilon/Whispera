import Foundation
import Testing

@testable import Whispera

struct CaptureInterruptionPolicyTests {
	@Test func engineStopMidRecordingRestartsTheInputInsteadOfRecordingSilence() {
		var policy = CaptureInterruptionPolicy()
		let response = policy.respond(
			to: .engineStopped, isRecording: true, isStarting: false, path: .stream, isRestarting: false)
		#expect(response == .restartInput)
		#expect(
			policy.respond(
				to: .inputDeviceChanged, isRecording: true, isStarting: false, path: .stream, isRestarting: false)
				== .restartInput)
	}

	@Test func aDeviceThatKeepsDroppingOutEndsTheRecordingWithANotice() {
		var policy = CaptureInterruptionPolicy()
		for _ in 0..<CaptureInterruptionPolicy.maxRestartsPerSession {
			#expect(
				policy.respond(
					to: .engineStopped, isRecording: true, isStarting: false, path: .stream, isRestarting: false)
					== .restartInput)
		}
		guard
			case .finish(let notice) = policy.respond(
				to: .engineStopped, isRecording: true, isStarting: false, path: .stream, isRestarting: false)
		else {
			Issue.record("Expected the recording to finish")
			return
		}
		#expect(!notice.isEmpty)

		policy.reset()
		#expect(
			policy.respond(to: .engineStopped, isRecording: true, isStarting: false, path: .stream, isRestarting: false)
				== .restartInput)
	}

	@Test func changesDuringARestartOrOffTheStreamPathAreIgnored() {
		var policy = CaptureInterruptionPolicy()
		#expect(
			policy.respond(to: .engineStopped, isRecording: true, isStarting: false, path: .stream, isRestarting: true)
				== .ignore)
		#expect(
			policy.respond(to: .engineStopped, isRecording: true, isStarting: false, path: .file, isRestarting: false)
				== .ignore)
		#expect(
			policy.respond(to: .engineStopped, isRecording: true, isStarting: false, path: .live, isRestarting: false)
				== .ignore)
		#expect(
			policy.respond(to: .engineStopped, isRecording: false, isStarting: false, path: nil, isRestarting: false)
				== .ignore)
		#expect(policy.restarts == 0)
	}

	@Test(arguments: [CaptureInterruption.systemSleep, .sessionResigned])
	func sleepAndUserSwitchStopTheRecordingOnEveryPath(_ interruption: CaptureInterruption) {
		for path in [CapturePath.stream, .file, .live] {
			var policy = CaptureInterruptionPolicy()
			guard
				case .finish(let notice) = policy.respond(
					to: interruption, isRecording: true, isStarting: false, path: path, isRestarting: false)
			else {
				Issue.record("\(interruption) on \(path) should finish the recording")
				continue
			}
			#expect(notice.contains("stopped"))
		}
		var policy = CaptureInterruptionPolicy()
		#expect(
			policy.respond(to: interruption, isRecording: false, isStarting: true, path: .stream, isRestarting: false)
				== .cancelStartup)
		#expect(
			policy.respond(to: interruption, isRecording: false, isStarting: false, path: nil, isRestarting: false)
				== .ignore)
	}

	@Test func captureLimitStopsTheRecordingAndSaysSo() {
		var policy = CaptureInterruptionPolicy()
		guard
			case .finish(let notice) = policy.respond(
				to: .captureLimitReached, isRecording: true, isStarting: false, path: .stream, isRestarting: false)
		else {
			Issue.record("Expected the recording to finish at the cap")
			return
		}
		#expect(notice.contains("\(StreamCaptureBuffer.maxMinutes)-minute"))
		#expect(
			policy.respond(
				to: .captureLimitReached, isRecording: false, isStarting: false, path: nil, isRestarting: false)
				== .ignore)
	}
}

@MainActor
struct ParakeetTextPipelineLanguageTests {
	@Test func parakeetDropsTheIgnoredLanguagePicker() {
		#expect(WhisperKitTranscriber.pipelineLanguageCode(selectedLanguage: "english", engineHonorsLanguage: false) == nil)
		#expect(WhisperKitTranscriber.pipelineLanguageCode(selectedLanguage: "english", engineHonorsLanguage: true) == "en")
	}

	/// With English still selected, Portuguese from Parakeet used to lose its "um" (a, one).
	@Test func portugueseFromParakeetKeepsWordsThatAreEnglishFillers() {
		let text = "Eu tenho um carro vermelho e uma casa muito grande perto da praia."
		let processor = TranscriptTextProcessor(configuration: TextProcessingConfiguration())

		let fromParakeet = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: WhisperKitTranscriber.pipelineLanguageCode(
				selectedLanguage: "english", engineHonorsLanguage: false),
			translating: false, modelDetectedLanguage: nil, text: text)
		#expect(processor.process(text, language: fromParakeet).contains(" um carro"))

		let fromWhisper = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: WhisperKitTranscriber.pipelineLanguageCode(
				selectedLanguage: "english", engineHonorsLanguage: true),
			translating: false, modelDetectedLanguage: nil, text: text)
		#expect(fromWhisper == .userSelected("en"))
	}
}

@MainActor
@Suite(.serialized, .sharedTranscriber)
struct ModelDownloadStateTests {
	/// Going offline or a Hugging Face error used to leave `isDownloadingModel` stuck on, which blocked
	/// idle unload, custom model import and the onboarding button until relaunch.
	@Test func failedDownloadClearsTheDownloadingState() async {
		let transcriber = WhisperKitTranscriber.shared
		let missing = "openai_whisper-does-not-exist-\(UUID().uuidString.prefix(8))"
		await #expect(throws: (any Error).self) {
			try await transcriber.downloadModel(missing)
		}
		#expect(!transcriber.isDownloadingModel)
		#expect(transcriber.downloadingModelName == nil)
		#expect(transcriber.downloadProgress == 0)
	}
}
