import AppKit
import SwiftUI

struct AutomationSettingsView: View {
	@AppStorage(RemoteControlSettings.urlSchemeEnabledKey) private var urlSchemeEnabled =
		RemoteControlSettings.urlSchemeEnabledDefault
	@State private var token: String?

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
		.onChange(of: urlSchemeEnabled, initial: true) { _, enabled in
			if enabled && token == nil { token = RemoteControlToken.load() }
		}
	}

	private var remoteControlSection: some View {
		SettingsSection("Remote Control") {
			SettingRow(
				"Allow whispera:// links",
				description:
					"Lets Stream Deck, launchers and scripts control dictation. Links that start dictation or switch the model must carry this Mac's private token, so web pages cannot open the mic. Stop and cancel links always work."
			) {
				Toggle("", isOn: $urlSchemeEnabled)
					.toggleStyle(.switch)
					.labelsHidden()
			}

			VStack(alignment: .leading, spacing: 6) {
				ForEach(Self.exampleCommands) { example in
					CopyableCommandRow(
						title: example.title, command: example.command.url(token: token).absoluteString)
				}
				Button("Reset Token") { resetToken() }
					.help("Invalidates every link and script that carries the current token")
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

	private func resetToken() {
		do {
			token = try RemoteControlToken.regenerate()
		} catch {
			AppLogger.shared.general.error("Could not reset the remote control token: \(error.localizedDescription)")
		}
	}

	private struct ExampleCommand: Identifiable {
		let title: String
		let command: RemoteCommand
		var id: String { title }
	}

	private static let exampleCommands: [ExampleCommand] = [
		ExampleCommand(title: "Toggle", command: .toggle),
		ExampleCommand(title: "Toggle + post-process", command: .togglePostProcess),
		ExampleCommand(title: "Start", command: .start),
		ExampleCommand(title: "Stop", command: .stop),
		ExampleCommand(title: "Cancel", command: .cancel),
		ExampleCommand(title: "Language", command: .setLanguage("german")),
		ExampleCommand(title: "Model", command: .setModel("openai_whisper-small.en")),
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
