import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct ChineseScriptConversionTests {
	@Test func traditionalToSimplified() {
		let result = TranscriptTextProcessor.convertChineseScript(
			"漢語開發", to: .simplified, language: .userSelected("zh"))
		#expect(result == "汉语开发")
	}

	@Test func simplifiedToTraditional() {
		let result = TranscriptTextProcessor.convertChineseScript(
			"汉语开发", to: .traditional, language: .modelDetected("zh"))
		#expect(result == "漢語開發")
	}

	@Test func unchangedLeavesScript() {
		let result = TranscriptTextProcessor.convertChineseScript(
			"漢語", to: .unchanged, language: .userSelected("zh"))
		#expect(result == "漢語")
	}

	@Test func nonChineseOutputIsNeverRewritten() {
		let japanese = "日本語の開発"
		#expect(
			TranscriptTextProcessor.convertChineseScript(japanese, to: .simplified, language: .userSelected("ja"))
				== japanese)
		#expect(
			TranscriptTextProcessor.convertChineseScript(japanese, to: .simplified, language: .unknown)
				== japanese)
	}

	@Test func textDetectedChineseScriptTagsCount() {
		#expect(
			TranscriptTextProcessor.convertChineseScript(
				"漢語", to: .simplified, language: .textDetected("zh-Hant"))
				== "汉语")
	}
}

struct ChineseScriptAutomaticTests {
	@Test(arguments: [
		(["zh-Hant-TW", "en-US"], ChineseScriptPreference.traditional),
		(["en-US", "zh-HK"], .traditional),
		(["zh-TW"], .traditional),
		(["zh-Hans-CN"], .simplified),
		(["zh-CN", "zh-TW"], .simplified),
		(["zh"], .simplified),
		(["yue-Hant-HK"], .traditional),
		(["en-US", "de-DE"], .unchanged),
		([], .unchanged),
	])
	func scriptFollowsTheFirstChineseLanguage(languages: [String], expected: ChineseScriptPreference) {
		#expect(ChineseScriptPreference.automaticScript(preferredLanguages: languages) == expected)
	}

	@Test func automaticConvertsChineseTranscriptsForATraditionalReader() {
		#expect(
			TranscriptTextProcessor.convertChineseScript(
				"汉语开发", to: .automatic, language: .modelDetected("zh"), preferredLanguages: ["zh-Hant-TW"])
				== "漢語開發")
	}

	@Test func automaticLeavesTranscriptsAloneWithoutAChineseLanguage() {
		#expect(
			TranscriptTextProcessor.convertChineseScript(
				"漢語", to: .automatic, language: .userSelected("zh"), preferredLanguages: ["en-US"]) == "漢語")
	}

	@Test func automaticNeverTouchesJapanese() {
		let japanese = "日本語の開発"
		#expect(
			TranscriptTextProcessor.convertChineseScript(
				japanese, to: .automatic, language: .modelDetected("ja"), preferredLanguages: ["zh-Hans-CN"])
				== japanese)
	}

	@Test func cantoneseOutputIsTreatedAsChinese() {
		#expect(
			TranscriptTextProcessor.convertChineseScript(
				"开发", to: .traditional, language: .modelDetected("yue")) == "開發")
	}

	@Test func pipelineUsesTheConfiguredPreferredLanguages() {
		var configuration = TextProcessingConfiguration()
		configuration.chineseScript = .automatic
		configuration.preferredLanguages = ["zh-Hans-CN"]
		configuration.fillerWordRemovalEnabled = false
		#expect(
			TranscriptTextProcessor(configuration: configuration).process("我們開會", language: .modelDetected("zh"))
				== "我们开会")
	}
}

struct ChineseScriptSettingsTests {
	private func makeDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "ChineseScriptSettingsTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsToFollowingThePreferredLanguages() {
		#expect(TextProcessingSettings.configuration(from: makeDefaults()).chineseScript == .automatic)
	}

	@Test func roundTrips() {
		let defaults = makeDefaults()
		defaults.set(
			ChineseScriptPreference.traditional.rawValue,
			forKey: TextProcessingSettings.Keys.chineseScriptConversion)
		#expect(TextProcessingSettings.configuration(from: defaults).chineseScript == .traditional)
	}

	@Test func unknownValueFallsBack() {
		let defaults = makeDefaults()
		defaults.set("klingon", forKey: TextProcessingSettings.Keys.chineseScriptConversion)
		#expect(TextProcessingSettings.configuration(from: defaults).chineseScript == .automatic)
	}

	@Test func conversionRunsInPipeline() {
		var configuration = TextProcessingConfiguration()
		configuration.chineseScript = .simplified
		let processor = TranscriptTextProcessor(configuration: configuration)
		#expect(processor.process("我們開會", language: .modelDetected("zh")) == "我们开会")
	}
}

extension TextProcessingWhisperKitTests {
	@Test(.timeLimit(.minutes(10)))
	func chineseOutputIsConvertedToSimplified() async throws {
		let whisperKit = try await loadWhisperKit()
		let audio = try speak("我們今天下午開會討論這個問題。", voice: "Meijia")
		defer { try? FileManager.default.removeItem(at: audio) }

		let results = try await whisperKit.transcribe(audioPath: audio.path, decodeOptions: autoOptions())
		let result = try #require(results.first)
		#expect(result.language == "zh")

		var configuration = TextProcessingConfiguration()
		configuration.chineseScript = .simplified
		let processed = TranscriptTextProcessor(configuration: configuration).process(
			result.text, language: .modelDetected(result.language))
		#expect(!processed.isEmpty)
		#expect(processed == processed.applyingTransform(StringTransform("Hant-Hans"), reverse: false))
		#expect(!processed.contains("們") && !processed.contains("開會"), "got \(processed)")
	}
}
