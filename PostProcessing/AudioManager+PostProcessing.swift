import Foundation

extension AudioManager {
	/// Runs the configured LLM over the transcript when this session asked for it. Failures fall
	/// back to the raw transcript so a flaky provider never costs the user their dictation.
	func postProcessIfRequested(_ transcript: String, requested: Bool) async -> String {
		guard requested else { return transcript }
		let outcome = await PostProcessingService().process(transcript)
		if case .failed(_, let error) = outcome {
			transcriptionError = "Post-processing failed, pasted the raw transcript: \(error)"
		}
		return outcome.text
	}
}
