import SwiftUI

struct TextInsertionSettingsView: View {
	@AppStorage(TextInsertionSettings.Keys.pasteMethod)
	private var pasteMethod: PasteMethod = .commandV
	@AppStorage(TextInsertionSettings.Keys.externalScriptPath)
	private var externalScriptPath = ""
	@AppStorage(TextInsertionSettings.Keys.autoSubmit)
	private var autoSubmit = false
	@AppStorage(TextInsertionSettings.Keys.autoSubmitKey)
	private var autoSubmitKey: AutoSubmitKey = .returnKey
	@AppStorage(TextInsertionSettings.Keys.appendTrailingSpace)
	private var appendTrailingSpace = false
	@AppStorage(TextInsertionSettings.Keys.clipboardHandling)
	private var clipboardHandling: ClipboardHandling = .restore
	@AppStorage(TextInsertionSettings.Keys.pasteDelayBeforeMs)
	private var pasteDelayBeforeMs = TextInsertionSettings.defaultPasteDelayMs
	@AppStorage(TextInsertionSettings.Keys.pasteDelayAfterMs)
	private var pasteDelayAfterMs = TextInsertionSettings.defaultPasteDelayMs

	var body: some View {
		ScrollView {
			VStack(spacing: 24) {
				SettingsSection("Insertion") {
					SettingRow("Insert Text By", description: pasteMethod.summary) {
						Picker("", selection: $pasteMethod) {
							ForEach(PasteMethod.allCases) { method in
								Text(method.displayName).tag(method)
							}
						}
						.labelsHidden()
						.frame(width: 240)
					}

					if pasteMethod == .externalScript {
						SettingRow(
							"Script",
							description: scriptDescription
						) {
							HStack(spacing: 8) {
								TextField("/path/to/script", text: $externalScriptPath)
									.textFieldStyle(.roundedBorder)
									.frame(width: 200)
								Button("Choose…") { chooseScript() }
									.buttonStyle(.bordered)
							}
						}
					}

					SettingRow(
						"Append Trailing Space",
						description: "Add a space after each transcript so the next one does not run into it"
					) {
						Toggle("", isOn: $appendTrailingSpace)
					}

					SettingRow(
						"Auto-Submit",
						description: "Press a key after inserting so chat boxes send the message"
					) {
						Toggle("", isOn: $autoSubmit)
					}

					if autoSubmit {
						SettingRow("Submit With") {
							Picker("", selection: $autoSubmitKey) {
								ForEach(AutoSubmitKey.allCases) { key in
									Text(key.displayName).tag(key)
								}
							}
							.labelsHidden()
							.frame(width: 240)
						}
					}

					if pasteMethod == .copyOnly || pasteMethod == .externalScript {
						Text("Live dictation always pastes as you speak.")
							.font(.caption)
							.foregroundColor(.secondary)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
				}

				Divider()

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

	private var scriptDescription: String {
		if externalScriptPath.isEmpty {
			return "Receives the transcript as $1 and in WHISPERA_TRANSCRIPT"
		}
		do {
			_ = try ExternalScriptRunner.validate(path: externalScriptPath)
			return "Receives the transcript as $1 and in WHISPERA_TRANSCRIPT"
		} catch {
			return error.localizedDescription
		}
	}

	private func chooseScript() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.prompt = "Use Script"
		if panel.runModal() == .OK, let url = panel.url {
			externalScriptPath = url.path
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
