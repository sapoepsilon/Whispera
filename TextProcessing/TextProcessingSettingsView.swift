import SwiftUI

struct TextProcessingSettingsSection: View {
	@AppStorage(TextProcessingSettings.Keys.fillerWordRemovalEnabled) private var fillerWordRemovalEnabled = true
	@AppStorage(TextProcessingSettings.Keys.biasDecodingWithCustomWords) private var biasDecoding =
		TextProcessingSettings.biasDecodingDefault
	@AppStorage(TextProcessingSettings.Keys.wordCorrectionThreshold) private var wordCorrectionThreshold =
		TextProcessingConfiguration.defaultWordCorrectionThreshold
	@AppStorage(TextProcessingSettings.Keys.chineseScriptConversion) private var chineseScriptRaw =
		ChineseScriptPreference.defaultValue.rawValue

	@State private var customWords = CustomWordsModel()
	@State private var newCustomWord = ""
	@State private var customFillerWordsText = TextProcessingSettings.customFillerWords().joined(
		separator: ", ")

	var body: some View {
		SettingsSection("Dictionary & Cleanup") {
			SettingRow(
				"Custom Words",
				description: "Names and terms Whisper should spell your way. Close mishearings are corrected."
			) {
				HStack(spacing: 6) {
					TextField("Add word", text: $newCustomWord)
						.textFieldStyle(.roundedBorder)
						.frame(width: 140)
						.onSubmit(addCustomWord)
						.accessibilityIdentifier("customWordField")
					Button("Add", action: addCustomWord)
						.disabled(newCustomWord.trimmingCharacters(in: .whitespaces).isEmpty)
				}
			}

			if !customWords.words.isEmpty {
				FlowingWordList(words: customWords.words, onRemove: removeCustomWord)
			}

			SettingRow(
				"Bias Recognition",
				description: "Pass custom words to Whisper as a prompt so it prefers those spellings"
			) {
				Toggle("", isOn: $biasDecoding)
					.onChange(of: biasDecoding) { _, _ in refreshDecodingOptions() }
			}

			SettingRow(
				"Correction Tolerance",
				description: "Higher also fixes looser mishearings; lower only fixes near-exact ones"
			) {
				HStack(spacing: 6) {
					Slider(
						value: $wordCorrectionThreshold,
						in: TextProcessingSettings.wordCorrectionThresholdRange
					)
					.frame(width: 120)
					Text(String(format: "%.2f", wordCorrectionThreshold))
						.font(.caption.monospacedDigit())
						.foregroundColor(.secondary)
				}
			}

			SettingRow(
				"Remove Filler Words",
				description: "Drop um, uh, hmm and repeated stutters, and squeeze extra spaces, in dictation and file transcripts. Dictation also joins line breaks into spaces; file transcripts keep them."
			) {
				Toggle("", isOn: $fillerWordRemovalEnabled)
					.accessibilityIdentifier("fillerWordRemovalToggle")
			}

			if fillerWordRemovalEnabled {
				SettingRow(
					"Extra Filler Words",
					description: "Comma-separated words to remove in every language"
				) {
					TextField("like, you know", text: $customFillerWordsText)
						.textFieldStyle(.roundedBorder)
						.frame(width: 180)
						.onChange(of: customFillerWordsText) { _, newValue in
							TextProcessingSettings.setCustomFillerWords(
								TextProcessingSettings.parseList(newValue))
						}
				}
			}

			SettingRow(
				"Chinese Output",
				description:
					"Convert Chinese transcripts to Simplified or Traditional characters. Match My Languages uses the Chinese variant in your macOS language list"
			) {
				Picker("Chinese Output", selection: $chineseScriptRaw) {
					ForEach(ChineseScriptPreference.allCases) { preference in
						Text(preference.displayName).tag(preference.rawValue)
					}
				}
				.labelsHidden()
				.frame(width: 150)
			}
		}
	}

	private func addCustomWord() {
		guard !TextProcessingSettings.parseList(newCustomWord).isEmpty else { return }
		customWords.add(newCustomWord)
		newCustomWord = ""
		refreshDecodingOptions()
	}

	private func removeCustomWord(_ word: String) {
		customWords.remove(word)
		refreshDecodingOptions()
	}

	private func refreshDecodingOptions() {
		WhisperKitTranscriber.shared.refreshDecodingOptions()
	}
}

/// The Custom Words list shown in Settings. It follows the stored list instead of caching it,
/// because links, the CLI, Raycast and the App Intent add words while Settings stays open.
@MainActor
@Observable
final class CustomWordsModel {
	private(set) var words: [String]
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private var observer: DefaultsKeyObserver?

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		words = TextProcessingSettings.customWords(from: defaults)
		observer = DefaultsKeyObserver(defaults: defaults, keys: [TextProcessingSettings.Keys.customWords]) {
			[weak self] in
			self?.reload()
		}
	}

	func add(_ input: String) {
		TextProcessingSettings.addCustomWords(TextProcessingSettings.parseList(input), in: defaults)
		reload()
	}

	func remove(_ word: String) {
		TextProcessingSettings.removeCustomWord(word, in: defaults)
		reload()
	}

	func reload() {
		let stored = TextProcessingSettings.customWords(from: defaults)
		if stored != words { words = stored }
	}
}

private struct FlowingWordList: View {
	let words: [String]
	let onRemove: (String) -> Void

	var body: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], spacing: 6) {
			ForEach(words, id: \.self) { word in
				HStack(spacing: 4) {
					Text(word)
						.font(.caption)
						.lineLimit(1)
						.truncationMode(.tail)
					Button {
						onRemove(word)
					} label: {
						Image(systemName: "xmark.circle.fill")
							.font(.caption)
							.foregroundColor(.secondary)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Remove \(word)")
				}
				.padding(.horizontal, 8)
				.padding(.vertical, 4)
				.background(Capsule().fill(Color.secondary.opacity(0.12)))
			}
		}
	}
}
