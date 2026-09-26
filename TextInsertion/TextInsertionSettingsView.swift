import SwiftUI

struct TextInsertionSettingsView: View {
	@AppStorage(TextInsertionSettings.Keys.clipboardHandling)
	private var clipboardHandling: ClipboardHandling = .restore

	var body: some View {
		ScrollView {
			VStack(spacing: 24) {
				SettingsSection("Clipboard") {
					SettingRow(
						"After Inserting",
						description:
							"Restore puts back whatever you had copied once the transcript is pasted"
					) {
						Picker("", selection: $clipboardHandling) {
							ForEach(ClipboardHandling.allCases) { handling in
								Text(handling.displayName).tag(handling)
							}
						}
						.labelsHidden()
						.frame(width: 240)
					}
				}
			}
			.padding(20)
		}
	}
}
