import SwiftUI

struct HotkeySettingsSection: View {
	@AppStorage(HotkeyBackend.defaultsKey) private var backendRaw = HotkeyBackend.eventMonitor.rawValue
	@State private var diagnostics = KeyboardDiagnostics.shared

	private var backend: Binding<HotkeyBackend> {
		Binding(
			get: { HotkeyBackend(rawValue: backendRaw) ?? .eventMonitor },
			set: { backendRaw = $0.rawValue }
		)
	}

	var body: some View {
		SettingsSection("Keyboard") {
			SettingRow("Shortcut backend", description: backend.wrappedValue.summary) {
				Picker("Shortcut backend", selection: backend) {
					ForEach(HotkeyBackend.allCases) { option in
						Text(option.title).tag(option)
					}
				}
				.labelsHidden()
				.frame(width: 160, alignment: .trailing)
			}

			if let message = diagnostics.backendMessage {
				Label(message, systemImage: "exclamationmark.triangle.fill")
					.font(.caption)
					.foregroundColor(.orange)
					.fixedSize(horizontal: false, vertical: true)
			}

			KeyboardDiagnosticPanel(diagnostics: diagnostics)
		}
	}
}

struct KeyboardDiagnosticPanel: View {
	let diagnostics: KeyboardDiagnostics

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Text("Keyboard diagnostic")
					.font(.subheadline)
				Spacer()
				Button(diagnostics.isCapturing ? "Stop" : "Start") {
					diagnostics.isCapturing ? diagnostics.stopCapture() : diagnostics.startCapture()
				}
				Button("Reset") { diagnostics.reset() }
			}

			Text(
				"Counts keyboard events Whispera receives so you can tell whether a shortcut is being delivered. Key identities are never recorded."
			)
			.font(.caption)
			.foregroundColor(.secondary)
			.fixedSize(horizontal: false, vertical: true)

			Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
				statusRow("Active backend", diagnostics.activeBackend.title)
				statusRow("Accessibility", diagnostics.accessibilityTrusted ? "Granted" : "Not granted")
				statusRow("Secure input", diagnostics.secureInputEnabled ? "On (monitors are blind)" : "Off")
				Divider().gridCellColumns(2)
				countRow("Key down", diagnostics.counts.keyDown)
				countRow("Key up", diagnostics.counts.keyUp)
				countRow("Modifier changes", diagnostics.counts.flagsChanged)
				countRow("Auto-repeats", diagnostics.counts.autoRepeats)
				countRow("From other apps", diagnostics.counts.global)
				countRow("While Whispera is focused", diagnostics.counts.local)
				Divider().gridCellColumns(2)
				countRow("Dictation shortcut fired", diagnostics.counts.dictationMatches)
				countRow("File shortcut fired", diagnostics.counts.fileSelectionMatches)
				countRow("Via event monitor", diagnostics.counts.eventMonitorMatches)
				countRow("Via system hotkey", diagnostics.counts.carbonMatches)
			}
			.font(.caption)
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
		.onDisappear { diagnostics.stopCapture() }
	}

	private func statusRow(_ label: String, _ value: String) -> some View {
		GridRow {
			Text(LocalizedStringKey(label)).foregroundColor(.secondary)
			Text(LocalizedStringKey(value))
		}
	}

	private func countRow(_ label: String, _ value: Int) -> some View {
		GridRow {
			Text(LocalizedStringKey(label)).foregroundColor(.secondary)
			Text("\(value)").monospacedDigit()
		}
	}
}
