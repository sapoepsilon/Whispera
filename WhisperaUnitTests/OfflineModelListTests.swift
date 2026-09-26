import Testing

@testable import Whispera

struct OfflineModelListTests {
	@Test func downloadedModelsStaySelectableWhenTheListCannotBeFetched() {
		let list = WhisperKitTranscriber.offlineModelList(
			downloaded: ["openai_whisper-tiny.en", "openai_whisper-large-v3_947MB", "openai_whisper-small"],
			additional: ["parakeet-tdt-0.6b-v3"])
		#expect(list.contains("openai_whisper-tiny.en"))
		#expect(list.contains("openai_whisper-large-v3_947MB"))
		#expect(list.contains("parakeet-tdt-0.6b-v3"))
		#expect(Array(list.prefix(WhisperKitTranscriber.fallbackModelIDs.count)) == WhisperKitTranscriber.fallbackModelIDs)
	}

	@Test func noDuplicatesAndNoNonWhisperIDsFromDisk() {
		let list = WhisperKitTranscriber.offlineModelList(
			downloaded: ["openai_whisper-small", "custom:my-model", "parakeet-tdt-0.6b-v3"],
			additional: ["parakeet-tdt-0.6b-v3", "custom:my-model"])
		#expect(list.count == Set(list).count)
		#expect(list.filter { $0 == "openai_whisper-small" }.count == 1)
		#expect(list.contains("custom:my-model"))
	}
}
