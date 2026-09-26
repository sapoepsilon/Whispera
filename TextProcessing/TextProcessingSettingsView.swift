import SwiftUI

struct TextProcessingSettingsSection: View {
	@AppStorage(TextProcessingSettings.Keys.fillerWordRemovalEnabled) private var fillerWordRemovalEnabled = true

	@State private var customFillerWordsText = TextProcessingSettings.customFillerWords().joined(
		separator: ", ")

	var body: some View {
		SettingsSection("Dictionary & Cleanup") {
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
}
