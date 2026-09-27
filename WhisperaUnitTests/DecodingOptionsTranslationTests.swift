import Testing
import WhisperKit

@testable import Whispera

@MainActor
struct DecodingOptionsTranslationTests {
	/// Every file transcription changes the timestamp settings through updateAdvancedSettings,
	/// which rebuilds the shared options. The rebuild flipped the task, so after a file the live
	/// text pipeline and the next pass saw translate where the user had transcribe, and back.
	@Test(arguments: [false, true])
	func changingADecodingSettingKeepsTheTranslationSetting(translating: Bool) {
		let transcriber = WhisperKitTranscriber.shared
		let saved = transcriber.decodingOptions
		defer { transcriber.decodingOptions = saved }
		transcriber.decodingOptions = transcriber.createDecodingOptions(enableTranslation: translating)

		transcriber.updateDecodingOptions()

		#expect(transcriber.decodingOptions?.task == (translating ? .translate : .transcribe))
	}
}
