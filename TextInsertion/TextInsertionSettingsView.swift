import SwiftUI

struct TextInsertionSettingsView: View {
	@AppStorage(TextInsertionSettings.Keys.clipboardHandling)
	private var clipboardHandling: ClipboardHandling = .restore
	@AppStorage(TextInsertionSettings.Keys.pasteDelayBeforeMs)
	private var pasteDelayBeforeMs = TextInsertionSettings.defaultPasteDelayMs
	@AppStorage(TextInsertionSettings.Keys.pasteDelayAfterMs)
	private var pasteDelayAfterMs = TextInsertionSettings.defaultPasteDelayMs

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

				Divider()

				SettingsSection("Advanced") {
					SettingRow(
						"Delay Before Paste",
						description: "Wait after writing the clipboard before sending Cmd-V"
					) {
						delayStepper(value: $pasteDelayBeforeMs)
					}

					SettingRow(
						"Delay After Paste",
						description:
							"Wait before restoring the clipboard; raise it if an app pastes your old clipboard"
					) {
						delayStepper(value: $pasteDelayAfterMs)
					}
				}
			}
			.padding(20)
		}
	}

	private func delayStepper(value: Binding<Int>) -> some View {
		Stepper(
			value: Binding(
				get: { value.wrappedValue },
				set: { value.wrappedValue = TextInsertionSettings.clampedDelay($0) }
			),
			in: TextInsertionSettings.delayRange,
			step: 10
		) {
			Text("\(value.wrappedValue) ms")
				.font(.system(.body, design: .monospaced))
				.frame(minWidth: 70, alignment: .trailing)
		}
	}
}
