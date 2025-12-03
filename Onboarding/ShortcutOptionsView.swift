//
//  ShortcutsOptionView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import SwiftUI

struct ShortcutOptionsView: View {
	@Binding var customShortcut: String
	@Binding var showingOptions: Bool
	@State private var isRecordingShortcut = false
	@State private var eventMonitor: Any?

	private let shortcutOptions = [
		"⌥⌘R", "⌃⌘R", "⇧⌘R",
		"⌥⌘T", "⌃⌘T", "⇧⌘T",
		"⌥⌘V", "⌃⌘V", "⇧⌘V",
	]

	var body: some View {
		VStack(spacing: 16) {
			Text("Choose a shortcut:")
				.font(.subheadline)
				.foregroundColor(.secondary)

			// Custom shortcut recording section
			VStack(spacing: 12) {
				HStack {
					Text("Record Custom:")
						.font(.subheadline)
						.foregroundColor(.primary)

					Spacer()

					Group {
						if isRecordingShortcut {
							Button(action: {
								stopRecording()
							}) {
								Text("Press keys...")
									.font(.system(.caption, design: .monospaced))
									.frame(minWidth: 80)
							}
							.buttonStyle(PrimaryButtonStyle(isRecording: true))
							.foregroundColor(.white)
						} else {
							Button(action: {
								startRecording()
							}) {
								Text("Record New")
									.font(.system(.caption, design: .monospaced))
									.frame(minWidth: 80)
							}
							.buttonStyle(SecondaryButtonStyle())
							.foregroundColor(.primary)
						}
					}
				}

				if isRecordingShortcut {
					Text("Press Command, Option, Control or Shift + another key")
						.font(.caption)
						.foregroundColor(.blue)
						.multilineTextAlignment(.center)
				}
			}
			.padding()
			.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

			Text("Or choose a preset:")
				.font(.caption)
				.foregroundColor(.secondary)

			LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
				ForEach(shortcutOptions, id: \.self) { shortcut in
					Group {
						if shortcut == customShortcut {
							Button(shortcut) {
								customShortcut = shortcut
								showingOptions = false
							}
							.buttonStyle(PrimaryButtonStyle(isRecording: false))
							.font(.system(.caption, design: .monospaced))
						} else {
							Button(shortcut) {
								customShortcut = shortcut
								showingOptions = false
							}
							.buttonStyle(SecondaryButtonStyle())
							.font(.system(.caption, design: .monospaced))
						}
					}
				}
			}

			Button("Cancel") {
				showingOptions = false
			}
			.buttonStyle(TertiaryButtonStyle())
			.font(.caption)
		}
		.padding()
		.background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
		.onDisappear {
			stopRecording()
		}
	}

	private func startRecording() {
		isRecordingShortcut = true

		eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
			if self.isRecordingShortcut {
				let shortcut = self.formatKeyEvent(event)
				if !shortcut.isEmpty {
					self.customShortcut = shortcut
					self.stopRecording()
					self.showingOptions = false
				}
				return nil
			}
			return event
		}
	}

	private func stopRecording() {
		isRecordingShortcut = false
		if let monitor = eventMonitor {
			NSEvent.removeMonitor(monitor)
			eventMonitor = nil
		}
	}

	private func formatKeyEvent(_ event: NSEvent) -> String {
		var parts: [String] = []
		let flags = event.modifierFlags

		if flags.contains(.command) { parts.append("⌘") }
		if flags.contains(.option) { parts.append("⌥") }
		if flags.contains(.control) { parts.append("⌃") }
		if flags.contains(.shift) { parts.append("⇧") }

		if let characters = event.charactersIgnoringModifiers?.uppercased() {
			parts.append(characters)
		}

		return flags.intersection([.command, .option, .control, .shift]).isEmpty ? "" : parts.joined()
	}
}
