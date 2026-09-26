import SwiftUI

struct TextInsertionSettingsView: View {
	@AppStorage(TextInsertionSettings.Keys.pasteMethod)
	private var pasteMethod: PasteMethod = .commandV
	@AppStorage(TextInsertionSettings.Keys.externalScriptPath)
	private var externalScriptPath = ""
	@AppStorage(TextInsertionSettings.Keys.externalScriptApproval)
	private var externalScriptApproval = ""
	@State private var scriptError: String?
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
	private var pasteDelayAfterMs = TextInsertionSettings.defaultPasteDelayAfterMs
	@AppStorage(TextInsertionSettings.Keys.clipboardRestoreHoldMs)
	private var clipboardRestoreHoldMs = TextInsertionSettings.defaultClipboardRestoreHoldMs

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
							// Read-only: the script must be picked with the file panel so it can be approved
							HStack(spacing: 8) {
								Text(externalScriptPath.isEmpty ? String(localized: "No script chosen") : externalScriptPath)
									.font(.system(.body, design: .monospaced))
									.foregroundColor(externalScriptPath.isEmpty ? .secondary : .primary)
									.lineLimit(1)
									.truncationMode(.middle)
									.frame(width: 200, alignment: .leading)
								Button("Choose…") { chooseScript() }
									.buttonStyle(.bordered)
							}
						}
					}

					SettingRow(
						"Append Trailing Space",
						description:
							"Add a space after each transcript so the next one does not run into it"
					) {
						Toggle("", isOn: $appendTrailingSpace)
					}

					SettingRow(
						"Auto-Submit",
						description:
							"Press a key after inserting so chat boxes send the message. Live dictation presses it once, when you stop."
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
							"Restore puts back what you had copied once the transcript is pasted. Exceptions: passwords and other concealed items are cleared rather than restored, anything larger than 16 MB per item or 32 MB in total is lost and the transcript stays, and files or images another app only promised to provide may come back incomplete."
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
							"Extra wait after the app reads the transcript before the clipboard is restored; raise it if an app pastes your old clipboard"
					) {
						delayStepper(value: $pasteDelayAfterMs)
					}

					SettingRow(
						"Minimum Hold After Paste",
						description:
							"The transcript stays on the clipboard at least this long after Cmd-V before the previous clipboard returns"
					) {
						Stepper(
							value: Binding(
								get: { clipboardRestoreHoldMs },
								set: { clipboardRestoreHoldMs = TextInsertionSettings.clampedHold($0) }
							),
							in: TextInsertionSettings.restoreHoldRange,
							step: 50
						) {
							Text("\(clipboardRestoreHoldMs) ms")
								.font(.system(.body, design: .monospaced))
								.frame(minWidth: 70, alignment: .trailing)
						}
					}
				}
			}
			.padding(20)
		}
		.alert(
			"Can't Use This Script",
			isPresented: Binding(get: { scriptError != nil }, set: { if !$0 { scriptError = nil } }),
			presenting: scriptError
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
	}

	private static let scriptUsage = String(
		localized:
			"Receives the transcript on standard input and in WHISPERA_TRANSCRIPT. Choose the script again after editing it."
	)

	private var scriptDescription: String {
		if externalScriptPath.isEmpty {
			return Self.scriptUsage
		}
		do {
			let url = try ExternalScriptRunner.validate(path: externalScriptPath)
			try ExternalScriptRunner.checkOwnershipAndPermissions(of: url.path)
			guard ScriptApproval.isApproved(path: url.path, approval: externalScriptApproval) else {
				return ExternalScriptError.notApproved.localizedDescription
			}
			return Self.scriptUsage
		} catch {
			return error.localizedDescription
		}
	}

	private func chooseScript() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.prompt = String(localized: "Use Script")
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			externalScriptApproval = try ScriptApproval.approve(path: url.path)
			externalScriptPath = url.path
		} catch {
			scriptError = error.localizedDescription
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
