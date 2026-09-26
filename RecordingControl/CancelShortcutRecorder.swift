import AppKit
import SwiftUI

/// Records the cancel key. Unlike the dictation shortcut it may be a bare non-typing key
/// (Esc, F-keys, Delete) because it is only listened for during a dictation.
struct CancelShortcutRecorder: View {
	@AppStorage(RecordingControlSettings.CancelKey.display) private var storedDisplay: String?
	@State private var isRecording = false
	@State private var monitor: Any?
	@State private var recorderToken: UUID?
	@State private var rejection: String?

	private var settings: RecordingControlSettings { RecordingControlSettings() }

	var body: some View {
		HStack(spacing: 4) {
			Button {
				isRecording ? stopRecording() : startRecording()
			} label: {
				Text(isRecording ? "Press keys..." : LocalizedStringKey(storedDisplay ?? CancelShortcutBinding.escape.display))
					.font(.system(.body, design: .monospaced))
					.frame(minWidth: 80)
			}
			.foregroundColor(isRecording ? .red : .primary)
			.accessibilityIdentifier("cancelShortcutRecorder")

			if storedDisplay != nil {
				Button {
					settings.resetCancelShortcut()
				} label: {
					Image(systemName: "arrow.uturn.backward")
				}
				.buttonStyle(.borderless)
				.help("Reset to Esc")
			}
		}
		.onDisappear(perform: stopRecording)
		.alert(
			"Shortcut not available",
			isPresented: Binding(get: { rejection != nil }, set: { if !$0 { rejection = nil } }),
			presenting: rejection
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
	}

	private func startRecording() {
		isRecording = true
		ShortcutRecorderGate.shared.end(recorderToken)
		recorderToken = ShortcutRecorderGate.shared.begin()
		monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
			guard isRecording else { return event }
			guard
				let binding = CancelShortcutBinding(
					keyCode: event.keyCode, modifiers: event.modifierFlags,
					characters: event.charactersIgnoringModifiers)
			else { return nil }
			stopRecording()
			save(binding)
			return nil
		}
	}

	private func save(_ binding: CancelShortcutBinding) {
		let defaults = UserDefaults.standard
		let taken = [
			ShortcutDefaults.dictation(in: defaults),
			ShortcutDefaults.fileSelection(in: defaults),
			PostProcessingSettings().shortcut,
		]
		switch binding.rejection(taken: taken) {
		case .needsModifier:
			rejection = String(
				localized:
					"\(binding.display) types text, so it needs a modifier such as ⌘, ⌥ or ⌃. Esc, Delete and the F-keys work on their own."
			)
		case .sameAsShortcut(let other):
			rejection = String(localized: "\(binding.display) is already used by another Whispera shortcut (\(other)).")
		case nil:
			settings.cancelShortcut = binding
			AppLogger.shared.general.info("Cancel shortcut set to \(binding.display)")
		}
	}

	private func stopRecording() {
		isRecording = false
		ShortcutRecorderGate.shared.end(recorderToken)
		recorderToken = nil
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
	}
}
