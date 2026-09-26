import SwiftUI

struct CommandLineSettingsSection: View {
	private var executablePath: String {
		Bundle.main.executableURL?.path ?? "/Applications/Whispera.app/Contents/MacOS/Whispera"
	}

	var body: some View {
		SettingsSection("Command Line") {
			Text(
				"The app binary doubles as a headless CLI. It uses models you already downloaded and never opens a window."
			)
			.font(.caption)
			.foregroundColor(.secondary)
			.fixedSize(horizontal: false, vertical: true)

			VStack(alignment: .leading, spacing: 6) {
				CopyableCommandRow(title: "Alias", command: "alias whispera='\(executablePath)'")
				CopyableCommandRow(title: "Transcribe", command: "whispera --transcribe-file talk.wav --json")
				CopyableCommandRow(title: "Benchmark", command: "whispera -f talk.wav --repeat 5 --device-index 3")
				CopyableCommandRow(title: "Models", command: "whispera --list-models")
				CopyableCommandRow(title: "Dictate", command: "whispera --toggle")
				CopyableCommandRow(title: "Help", command: "whispera --help")
			}
		}
	}
}
