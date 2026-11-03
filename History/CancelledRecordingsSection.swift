import SwiftUI

/// Menu bar section listing recordings kept by a cancel, so an accidental Escape can be
/// transcribed after all. Hidden while there are none.
struct CancelledRecordingsSection: View {
	var audioManager: AudioManager
	var store: CancelledRecordingStore = .shared

	static let visibleCount = 3

	var body: some View {
		if !store.recordings.isEmpty {
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text("Cancelled recordings")
						.font(.caption)
						.foregroundColor(.secondary)
					Spacer()
					if store.recordings.count > 1 {
						Button("Clear") { store.deleteAll() }
							.buttonStyle(.plain)
							.font(.caption)
							.foregroundColor(.secondary)
							.help("Delete all cancelled recordings")
							.accessibilityIdentifier("cancelledRecordingsClearButton")
					}
				}

				ForEach(store.recordings.prefix(Self.visibleCount)) { recording in
					CancelledRecordingRow(
						recording: recording,
						isTranscribing: store.transcribingID == recording.id,
						isBusy: store.transcribingID != nil,
						onTranscribe: {
							Task {
								await audioManager.transcribeCancelledRecording(recording, store: store)
							}
						},
						onStop: { store.cancelTranscription() },
						onDelete: { store.delete(recording) }
					)
				}
			}
			.padding(12)
			.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
			.accessibilityIdentifier("cancelledRecordingsSection")
		}
	}
}

struct CancelledRecordingRow: View {
	let recording: CancelledRecording
	let isTranscribing: Bool
	let isBusy: Bool
	let onTranscribe: () -> Void
	let onStop: () -> Void
	let onDelete: () -> Void

	private var durationText: String {
		Duration.seconds(recording.durationSeconds.rounded(.up))
			.formatted(.time(pattern: .minuteSecond))
	}

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "waveform.badge.exclamationmark")
				.foregroundColor(.secondary)
			Text("\(recording.createdAt, format: .dateTime.hour().minute()) · \(durationText)")
				.font(.system(.subheadline, design: .rounded))
				.monospacedDigit()
			Spacer()
			if isTranscribing {
				ProgressView()
					.controlSize(.small)
				Button("Stop", action: onStop)
					.buttonStyle(.plain)
					.font(.caption)
					.foregroundColor(.blue)
					.help("Stop transcribing this recording")
			} else {
				Button("Transcribe", action: onTranscribe)
					.buttonStyle(.plain)
					.font(.caption)
					.foregroundColor(isBusy ? .secondary : .blue)
					.disabled(isBusy)
					.help("Transcribe and copy to the clipboard")
					.accessibilityIdentifier("cancelledRecordingTranscribeButton")
			}
			Button(action: onDelete) {
				Image(systemName: "trash")
					.font(.caption)
			}
			.buttonStyle(.plain)
			.foregroundColor(.secondary)
			.help("Delete this recording")
			.accessibilityIdentifier("cancelledRecordingDeleteButton")
		}
	}
}
