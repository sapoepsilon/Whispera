import AppKit
import SwiftUI

struct LauncherSettingsSection: View {
	@State private var exportResult: ExportResult?

	struct ExportResult: Identifiable {
		let id = UUID()
		let title: String
		let message: String
	}

	var body: some View {
		SettingsSection("Launchers") {
			SettingRow(
				"Raycast script commands",
				description:
					"Control dictation, copy the last transcript, open history, add dictionary words, switch language or model, and transcribe a file from Raycast. Apart from stop, cancel, listing models and transcribing a file, they need \"Allow whispera:// links\" turned on above. Pick the folder you added under Raycast > Extensions > Script Commands."
			) {
				Button("Export...") { exportScripts() }
			}
		}
		.alert(
			exportResult?.title ?? "",
			isPresented: Binding(get: { exportResult != nil }, set: { if !$0 { exportResult = nil } }),
			presenting: exportResult
		) { _ in
			Button("OK") {}
		} message: { result in
			Text(result.message)
		}
	}

	private func exportScripts() {
		let panel = NSOpenPanel()
		panel.title = String(localized: "Choose a Raycast Script Commands Folder")
		panel.prompt = String(localized: "Export")
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let directory = panel.url else { return }

		let cliPath = Bundle.main.executableURL?.path ?? RaycastScripts.defaultCLIPath
		let bundleIdentifier = Bundle.main.bundleIdentifier ?? RaycastScripts.defaultBundleIdentifier
		do {
			let files = try RaycastScripts.export(to: directory, cliPath: cliPath, bundleIdentifier: bundleIdentifier)
			AppLogger.shared.general.info("Exported \(files.count) Raycast scripts to \(directory.path)")
			var message = String(
				localized:
					"\(files.count) script commands saved to \(directory.path). Raycast picks them up automatically."
			)
			if !RemoteControlSettings.isURLSchemeEnabled() {
				message += "\n\n"
					+ String(
						localized:
							"\"Allow whispera:// links\" is off, so the commands that control Whispera will only tell you to turn it on. Turn it on in Settings > Automation."
					)
			}
			exportResult = ExportResult(title: String(localized: "Scripts Exported"), message: message)
		} catch {
			AppLogger.shared.general.error("Raycast script export failed: \(error.localizedDescription)")
			exportResult = ExportResult(
				title: String(localized: "Export Failed"), message: error.localizedDescription)
		}
	}
}
