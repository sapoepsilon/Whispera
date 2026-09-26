import AppKit
import SwiftUI

struct AutomationSettingsView: View {
	@AppStorage(RemoteControlSettings.urlSchemeEnabledKey) private var urlSchemeEnabled = true

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				remoteControlSection
				LauncherSettingsSection()
				CommandLineSettingsSection()
				HotkeySettingsSection()
			}
			.padding(20)
		}
	}

	private var remoteControlSection: some View {
		SettingsSection("Remote Control") {
			SettingRow(
				"Allow whispera:// links",
				description:
					"Lets Stream Deck, launchers, scripts and browser links start, stop or cancel dictation."
			) {
				Toggle("", isOn: $urlSchemeEnabled)
					.toggleStyle(.switch)
					.labelsHidden()
			}

			VStack(alignment: .leading, spacing: 6) {
				ForEach(Self.exampleCommands, id: \.url) { example in
					CopyableCommandRow(title: example.title, command: example.url)
				}
			}
			.disabled(!urlSchemeEnabled)
			.opacity(urlSchemeEnabled ? 1 : 0.5)

			Text(
				"Shortcuts and Spotlight also list Toggle, Start, Stop and Cancel Dictation, Set Dictation Language and Transcribe Audio File actions. They work even when links are off."
			)
			.font(.caption)
			.foregroundColor(.secondary)
			.fixedSize(horizontal: false, vertical: true)
		}
	}

	private static let exampleCommands: [(title: String, url: String)] = [
		("Toggle", RemoteCommand.toggle.url.absoluteString),
		("Start", RemoteCommand.start.url.absoluteString),
		("Stop", RemoteCommand.stop.url.absoluteString),
		("Cancel", RemoteCommand.cancel.url.absoluteString),
		("Language", RemoteCommand.setLanguage("german").url.absoluteString),
		("Model", RemoteCommand.setModel("openai_whisper-small.en").url.absoluteString),
	]
}

struct CopyableCommandRow: View {
	let title: String
	let command: String

	var body: some View {
		HStack(spacing: 8) {
			Text(title)
				.font(.caption)
				.foregroundColor(.secondary)
				.frame(width: 70, alignment: .leading)
			Text(command)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 4)
			Button {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(command, forType: .string)
			} label: {
				Image(systemName: "doc.on.doc")
			}
			.buttonStyle(.borderless)
			.help("Copy")
		}
	}
}
