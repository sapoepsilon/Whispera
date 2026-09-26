import Foundation

/// The text to deliver for one dictation, plus what history should record about the LLM pass.
struct PostProcessedTranscript: Equatable {
	let text: String
	let history: HistoryPostProcessing?
}

extension AudioManager {
	/// Runs the configured LLM over the transcript when this session asked for it. Failures fall
	/// back to the raw transcript so a flaky provider never costs the user their dictation.
	func postProcessIfRequested(_ transcript: String) async -> PostProcessedTranscript {
		guard postProcessCurrentSession else { return PostProcessedTranscript(text: transcript, history: nil) }
		postProcessCurrentSession = false
		let run = await PostProcessingService().run(transcript)
		if case .failed(_, let error) = run.outcome {
			transcriptionError = "Post-processing failed, pasted the raw transcript: \(error)"
		}
		return PostProcessedTranscript(text: run.outcome.text, history: HistoryPostProcessing(run))
	}
}
