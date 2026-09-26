import SwiftUI

struct TextProcessingSettingsSection: View {
	@AppStorage(TextProcessingSettings.Keys.fillerWordRemovalEnabled) private var fillerWordRemovalEnabled = true
	@AppStorage(TextProcessingSettings.Keys.biasDecodingWithCustomWords) private var biasDecoding =
		TextProcessingSettings.biasDecodingDefault
	@AppStorage(TextProcessingSettings.Keys.wordCorrectionThreshold) private var wordCorrectionThreshold =
		TextProcessingConfiguration.defaultWordCorrectionThreshold

	@State private var customWords: [String] = TextProcessingSettings.customWords()
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

			if !customWords.isEmpty {
				FlowingWordList(words: customWords, onRemove: removeCustomWord)
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
				description: "Drop um, uh, hmm and repeated stutters from dictation"
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
		}
	}

	private func addCustomWord() {
		let additions = TextProcessingSettings.parseList(newCustomWord)
		guard !additions.isEmpty else { return }
		customWords = TextProcessingSettings.sanitizedList(customWords + additions)
		TextProcessingSettings.setCustomWords(customWords)
		newCustomWord = ""
		refreshDecodingOptions()
	}

	private func removeCustomWord(_ word: String) {
		customWords.removeAll { $0 == word }
		TextProcessingSettings.setCustomWords(customWords)
		refreshDecodingOptions()
	}

	private func refreshDecodingOptions() {
		WhisperKitTranscriber.shared.refreshDecodingOptions()
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
