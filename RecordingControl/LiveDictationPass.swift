import Foundation
import WhisperKit

/// The samples a live session has captured so far: the microphone buffer in the app, a clip in tests.
@MainActor
protocol LiveAudioSource {
	var sampleCount: Int { get }
	/// A copy of the samples from `start` on, and nothing before it.
	func samples(from start: Int) -> [Float]
}

/// WhisperKit's live microphone buffer. Only the part a pass decodes is copied out: holding the
/// whole buffer would also make the recorder copy all of it on its next append.
struct WhisperKitLiveAudio: LiveAudioSource {
	let processor: any AudioProcessing

	var sampleCount: Int { processor.audioSamples.count }

	func samples(from start: Int) -> [Float] {
		let all = processor.audioSamples
		return Array(all[min(start, all.count)...])
	}
}

/// What one live decode produced, with times relative to the start of the audio it was given.
struct LiveDecodeOutput: Sendable {
	var segments: [LiveSegment]
	var language: String?
}

/// Decodes one window of live audio.
typealias LiveDecoder = @MainActor ([Float], DecodingOptions) async throws -> LiveDecodeOutput?

struct LivePassSettings {
	var base: DecodingOptions
	var voiceActivity: VoiceActivitySettings
	/// The custom words behind the prompt in `base`, to spot the decoder echoing them.
	var promptWords: [String]
	/// How much new audio a pass waits for.
	var minimumNewAudioSeconds: Float = 0.3
}

/// One live dictation session's decode loop. The app's realtime loop and the tests' replay both
/// drive it, so what the tests replay is the production pass.
///
/// Each pass decodes only the audio after the confirmation point, and stopping decodes whatever
/// was captured after the newest pass once more, so the last words before the stop are typed.
@MainActor
final class LiveDictationPass {
	enum Step: Equatable {
		/// Less than `minimumNewAudioSeconds` of audio arrived since the last decode.
		case waitingForAudio
		/// The new audio holds no speech and Skip Silence is on.
		case silence
		/// The decoder found nothing, so the confirmer and the pending tail are untouched.
		case noSegments
		/// The session ended while the pass ran; nothing was changed.
		case stale
		case decoded(LiveSegmentConfirmer.Result)
	}

	private(set) var confirmer: LiveSegmentConfirmer
	/// The end of the audio the newest pass started decoding, in samples.
	private(set) var decodedThroughSample = 0
	/// The end of the audio behind `pendingTail`: a pass the session outlived does not count.
	private(set) var appliedThroughSample = 0
	/// The unconfirmed segments of the newest pass: what stopping types if no final decode can run.
	private(set) var pendingTail = ""
	/// The session language; with automatic detection, the language the newest pass heard until it
	/// is settled.
	private(set) var language: String?
	/// Whether automatic detection has settled on `language` for the rest of the session.
	private(set) var languageIsSettled = false

	init(holdBack: Int = WhisperKitTranscriber.liveSegmentsHeldBack) {
		confirmer = LiveSegmentConfirmer(holdBack: holdBack)
	}

	func step(
		audio: some LiveAudioSource, settings: LivePassSettings, decode: LiveDecoder,
		process: (String) -> String, isCurrent: () -> Bool = { true }
	) async throws -> Step {
		let total = audio.sampleCount
		let newSeconds = Float(total - decodedThroughSample) / Float(WhisperKit.sampleRate)
		guard newSeconds > settings.minimumNewAudioSeconds else { return .waitingForAudio }

		let windowStart = min(total, Int(confirmer.confirmedThroughSeconds * Float(WhisperKit.sampleRate)))
		let window = audio.samples(from: windowStart)
		let newFrom = min(window.count, max(0, decodedThroughSample - windowStart))
		let speech = await Self.speech(in: window, newFrom: newFrom, voiceActivity: settings.voiceActivity)
		guard isCurrent() else { return .stale }
		// Mirrors WhisperKit's own stream VAD: re-transcribing silence only yields hallucinated text
		guard speech.inNewAudio else { return .silence }

		decodedThroughSample = windowStart + window.count
		let options = liveOptions(settings.base, windowHasSpeech: speech.inWindow)
		let output = try await decode(window, options)
		guard isCurrent() else { return .stale }
		appliedThroughSample = decodedThroughSample
		guard let output, !output.segments.isEmpty else { return .noSegments }
		noteLanguage(output.language)

		let result = confirmer.apply(
			sessionSegments(output.segments, window: window, windowStart: windowStart, options: options, settings: settings),
			audioSeconds: Float(windowStart + window.count) / Float(WhisperKit.sampleRate),
			process: process)
		pendingTail = result.pendingText
		if result.confirmedSegmentCount > 0 {
			// The first confirmation was decoded from the session start, so its language comes from
			// at least holdBack + 1 segments of speech rather than a second of it
			languageIsSettled = language != nil
		}
		return .decoded(result)
	}

	/// The text stopping still has to type. Everything after the confirmation point is decoded
	/// once more when audio arrived after the newest pass; the newest pass's pending tail is used
	/// when there is no such audio, it holds no speech with Skip Silence on, or the final decode
	/// fails, finds nothing or runs past `timeLimit`.
	func finish(
		audio: some LiveAudioSource, settings: LivePassSettings, decode: @escaping LiveDecoder,
		timeLimit: Duration, isCurrent: () -> Bool = { true }
	) async -> String {
		let total = audio.sampleCount
		guard total > appliedThroughSample else { return pendingTail }
		let windowStart = min(total, Int(confirmer.confirmedThroughSeconds * Float(WhisperKit.sampleRate)))
		let window = audio.samples(from: windowStart)
		let newFrom = min(window.count, max(0, appliedThroughSample - windowStart))
		let speech = await Self.speech(in: window, newFrom: newFrom, voiceActivity: settings.voiceActivity)
		guard isCurrent(), speech.inNewAudio else { return pendingTail }

		let options = liveOptions(settings.base, windowHasSpeech: speech.inWindow)
		let work = Task { @MainActor in try await decode(window, options) }
		let deadline = Task {
			try await Task.sleep(for: timeLimit)
			work.cancel()
		}
		defer { deadline.cancel() }
		let output: LiveDecodeOutput?
		do {
			// Throwing the stop away (a cancel or reset) cancels the decode as well
			output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
		} catch {
			AppLogger.shared.liveTranscriber.error("Final live decode did not finish: \(error.localizedDescription)")
			return pendingTail
		}
		guard isCurrent(), let output, !output.segments.isEmpty else { return pendingTail }
		noteLanguage(output.language)
		let segments = sessionSegments(
			output.segments, window: window, windowStart: windowStart, options: options, settings: settings)
		decodedThroughSample = windowStart + window.count
		appliedThroughSample = decodedThroughSample
		pendingTail = confirmer.unconfirmedText(segments)
		return pendingTail
	}

	/// The options for one pass over a window that starts at the confirmation point. Timestamps
	/// are on because confirmation needs them; the custom-word prompt is left out while the window
	/// holds no speech, because Whisper echoes it on silence; a settled language is not detected again.
	func liveOptions(_ base: DecodingOptions, windowHasSpeech: Bool) -> DecodingOptions {
		var options = WhisperKitTranscriber.liveDecodingOptions(base, windowHasSpeech: windowHasSpeech)
		if base.language == nil, languageIsSettled, let language {
			options.language = language
			options.detectLanguage = false
		}
		return options
	}

	private func noteLanguage(_ detected: String?) {
		guard !languageIsSettled, let detected, !detected.isEmpty else { return }
		language = detected
	}

	/// A decode's segments on the session clock, without stray quotes or prompt echoes.
	private func sessionSegments(
		_ segments: [LiveSegment], window: [Float], windowStart: Int, options: DecodingOptions, settings: LivePassSettings
	) -> [LiveSegment] {
		let offset = Float(windowStart) / Float(WhisperKit.sampleRate)
		return WhisperKitTranscriber.liveSegments(
			segments, promptWords: options.promptTokens == nil ? [] : settings.promptWords, audio: window,
			sensitivity: settings.voiceActivity.sensitivity
		).map { LiveSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
	}

	/// Whether the audio since the last decode holds speech (always true with Skip Silence off)
	/// and whether the whole window does, judged off the main thread.
	private nonisolated static func speech(
		in window: [Float], newFrom: Int, voiceActivity: VoiceActivitySettings
	) async -> (inNewAudio: Bool, inWindow: Bool) {
		let trimmer = VoiceActivityTrimmer(sensitivity: voiceActivity.sensitivity)
		let inNewAudio = !voiceActivity.enabled || trimmer.hasSpeech(window[newFrom...])
		return (inNewAudio, trimmer.hasSpeech(window[...]))
	}
}
