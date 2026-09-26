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
					"Toggle, start, stop and cancel dictation, switch language or model, and transcribe a file from Raycast. Pick the folder you added under Raycast > Extensions > Script Commands."
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
		panel.title = "Choose a Raycast Script Commands Folder"
		panel.prompt = "Export"
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let directory = panel.url else { return }

		let cliPath = Bundle.main.executableURL?.path ?? RaycastScripts.defaultCLIPath
		do {
			let files = try RaycastScripts.export(to: directory, cliPath: cliPath)
			AppLogger.shared.general.info("Exported \(files.count) Raycast scripts to \(directory.path)")
			exportResult = ExportResult(
				title: "Scripts Exported",
				message: "\(files.count) script commands saved to \(directory.path). Raycast picks them up automatically."
			)
		} catch {
			AppLogger.shared.general.error("Raycast script export failed: \(error.localizedDescription)")
			exportResult = ExportResult(title: "Export Failed", message: error.localizedDescription)
		}
	}
}
