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
	/// Only the dictation shortcut can be a modifier on its own; the file shortcut is a keyDown hotkey.
	var allowsModifierOnly = false
	@State private var isRecordingShortcut = false
	@State private var modifierRecording = ModifierOnlyRecording()
	@State private var eventMonitor: Any?
	@State private var recorderToken: UUID?
	@State private var rejectedKey = false

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
					Text(recordingHint)
					.font(.caption)
					.foregroundColor(rejectedKey ? .orange : .blue)
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

	private var recordingHint: LocalizedStringKey {
		switch (rejectedKey, allowsModifierOnly) {
		case (true, false):
			return "That key can't be used. Press Command, Option, Control or Shift + another key"
		case (false, false):
			return "Press Command, Option, Control or Shift + another key"
		case (true, true):
			return
				"That key can't be used. Press Command, Option, Control or Shift + another key, or tap Right ⌘, Right ⌥, Right ⌃, Right ⇧ or Fn on its own"
		case (false, true):
			return
				"Press Command, Option, Control or Shift + another key, or tap Right ⌘, Right ⌥, Right ⌃, Right ⇧ or Fn on its own"
		}
	}

	private func startRecording() {
		isRecordingShortcut = true
		rejectedKey = false
		modifierRecording = ModifierOnlyRecording()
		ShortcutRecorderGate.shared.end(recorderToken)
		recorderToken = ShortcutRecorderGate.shared.begin()

		let mask: NSEvent.EventTypeMask = allowsModifierOnly ? [.keyDown, .flagsChanged] : [.keyDown]
		eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
			if self.isRecordingShortcut, !SyntheticKeyEvent.isSelfPosted(event) {
				if event.type == .flagsChanged {
					if let key = self.modifierRecording.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags) {
						self.customShortcut = key.rawValue
						self.stopRecording()
						self.showingOptions = false
					}
					return event
				}
				self.modifierRecording.keyDown()
				// Same formatter as Settings, so ⌥Space and F-keys are saved as names the
				// shortcut parser reads back instead of raw characters
				if let shortcut = DictationShortcutFormatter.format(
					keyCode: event.keyCode, modifiers: event.modifierFlags)
				{
					self.customShortcut = shortcut
					self.stopRecording()
					self.showingOptions = false
				} else {
					self.rejectedKey = true
				}
				return nil
			}
			return event
		}
	}

	private func stopRecording() {
		isRecordingShortcut = false
		ShortcutRecorderGate.shared.end(recorderToken)
		recorderToken = nil
		if let monitor = eventMonitor {
			NSEvent.removeMonitor(monitor)
			eventMonitor = nil
		}
	}
}

// Low-contrast text-only button style. Formerly defined alongside the menu-bar
// button styles; rehomed here after the menu-bar redesign removed its popover
// consumers, leaving this onboarding Cancel action as the sole user.
struct TertiaryButtonStyle: ButtonStyle {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(.caption, design: .rounded))
			.foregroundColor(.secondary)
			.opacity(configuration.isPressed ? 0.7 : 1.0)
			.scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale : 1.0)
			.animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
	}
}
