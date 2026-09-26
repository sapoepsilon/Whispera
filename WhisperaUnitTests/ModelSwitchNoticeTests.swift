import Foundation
import Testing

@testable import Whispera

struct ModelSwitchNoticeTests {

	private let identity: (String) -> String = { $0 }

	@Test func noNoticeWithoutALoadOrDownload() {
		#expect(
			ModelSwitchNotice.make(
				activeModel: "openai_whisper-small", hasLoadedEngine: true, loadingModel: nil,
				downloadingModel: nil) == nil)
	}

	@Test func loadingADifferentModelKeepsTheLoadedOneTranscribing() throws {
		let notice = try #require(
			ModelSwitchNotice.make(
				activeModel: "openai_whisper-small", hasLoadedEngine: true,
				loadingModel: "parakeet-tdt-0.6b-v3", downloadingModel: nil))
		#expect(notice.phase == .loading)
		#expect(notice.pendingModel == "parakeet-tdt-0.6b-v3")
		#expect(notice.activeModel == "openai_whisper-small")
		#expect(notice.pillText(name: identity) != nil)
	}

	@Test func reloadingTheSameModelIsNotASwitch() {
		#expect(
			ModelSwitchNotice.make(
				activeModel: "openai_whisper-small", hasLoadedEngine: true,
				loadingModel: "openai_whisper-small", downloadingModel: nil) == nil)
	}

	@Test func withoutALoadedEngineDictationWaits() throws {
		// After an idle unload currentModel still names the released model
		let notice = try #require(
			ModelSwitchNotice.make(
				activeModel: "openai_whisper-small", hasLoadedEngine: false,
				loadingModel: "openai_whisper-small", downloadingModel: nil))
		#expect(notice.activeModel == nil)
		#expect(notice.pillText(name: identity) == nil)
		#expect(notice.detail(name: identity) == String(localized: "Dictation waits until it is ready"))
	}

	@Test func downloadIsReportedUntilTheLoadStarts() throws {
		let notice = try #require(
			ModelSwitchNotice.make(
				activeModel: "openai_whisper-base", hasLoadedEngine: true, loadingModel: nil,
				downloadingModel: "openai_whisper-medium"))
		#expect(notice.phase == .downloading)
		#expect(notice.pendingModel == "openai_whisper-medium")
	}

	@Test func loadTakesPriorityOverADownloadName() throws {
		let notice = try #require(
			ModelSwitchNotice.make(
				activeModel: "openai_whisper-base", hasLoadedEngine: true,
				loadingModel: "openai_whisper-medium", downloadingModel: "openai_whisper-medium"))
		#expect(notice.phase == .loading)
	}

	@Test func textsNameBothModels() throws {
		let notice = try #require(
			ModelSwitchNotice.make(
				activeModel: "small", hasLoadedEngine: true, loadingModel: "parakeet",
				downloadingModel: nil))
		let upper: (String) -> String = { $0.uppercased() }
		#expect(notice.title(name: upper).contains("PARAKEET"))
		#expect(notice.detail(name: upper).contains("SMALL"))
		let pill = try #require(notice.pillText(name: upper))
		#expect(pill.contains("SMALL"))
		#expect(pill.contains("PARAKEET"))
	}

	@Test func mediumNameDropsTheSize() {
		#expect(ModelSwitchNotice.mediumName("Small (Multilingual) - 244MB") == "Small (Multilingual)")
		#expect(ModelSwitchNotice.mediumName("Large v3 Turbo") == "Large v3 Turbo")
	}

	@Test func shortNameDropsTheSizeAndTheQualifier() {
		#expect(
			ModelSwitchNotice.shortName("Parakeet TDT v3 (25 languages, auto-detect) - 460MB")
				== "Parakeet TDT v3")
		#expect(ModelSwitchNotice.shortName("Small (English) - 244MB") == "Small")
		#expect(ModelSwitchNotice.shortName("Custom: my-model") == "Custom: my-model")
	}

	@MainActor @Test func shortModelNamesForRealModelIDs() {
		#expect(WhisperKitTranscriber.shortModelName(for: "openai_whisper-small") == "Small")
		#expect(WhisperKitTranscriber.mediumModelName(for: "openai_whisper-small") == "Small (Multilingual)")
		#expect(WhisperKitTranscriber.shortModelName(for: "parakeet-tdt-0.6b-v3").hasPrefix("Parakeet TDT v3"))
	}
}
