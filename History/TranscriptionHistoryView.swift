import AVFoundation
import AppKit
import SwiftUI

@MainActor
@Observable
final class HistoryAudioPlayer: NSObject, AVAudioPlayerDelegate {
	private(set) var playingID: UUID?
	@ObservationIgnored private var player: AVAudioPlayer?

	func toggle(id: UUID, url: URL) {
		if playingID == id {
			stop()
			return
		}
		stop()
		do {
			let player = try AVAudioPlayer(contentsOf: url)
			player.delegate = self
			player.play()
			self.player = player
			playingID = id
		} catch {
			AppLogger.shared.ui.error("Failed to play history audio: \(error.localizedDescription)")
		}
	}

	func stop() {
		player?.stop()
		player = nil
		playingID = nil
	}

	nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		Task { @MainActor in
			self.player = nil
			self.playingID = nil
		}
	}
}

struct TranscriptionHistoryView: View {
	@State private var store = TranscriptionHistoryStore.shared
	@State private var player = HistoryAudioPlayer()
	@State private var searchText = ""
	@State private var starredOnly = false
	@State private var errorMessage: String?
	@State private var showingClearConfirmation = false
	@State private var copiedID: UUID?
	@State private var pendingPurge: HistoryPurge?
	@State private var pendingRetention: RetentionChange?

	/// A retention change that would delete entries straight away, held until the user confirms.
	struct RetentionChange: Identifiable {
		let id = UUID()
		let periodRaw: String
		let limit: Int
		let deletionCount: Int
	}

	enum HistoryPurge: Identifiable {
		case everything(count: Int)
		case recordings

		var id: String {
			switch self {
			case .everything: return "everything"
			case .recordings: return "recordings"
			}
		}
	}

	@AppStorage(HistorySettings.enabledKey) private var historyEnabled = HistorySettings.defaultEnabled
	@AppStorage(HistorySettings.saveAudioKey) private var saveAudio = HistorySettings.defaultSaveAudio
	@AppStorage(HistorySettings.retentionKey) private var retentionRaw = HistorySettings.defaultRetention
		.rawValue
	@AppStorage(HistorySettings.limitKey) private var historyLimit = HistorySettings.defaultLimit
	@AppStorage(PostProcessingSettings.Key.enabled) private var postProcessingEnabled = false

	private var filteredEntries: [TranscriptionHistoryEntry] {
		TranscriptionHistoryStore.filter(store.entries, query: searchText, starredOnly: starredOnly)
	}

	var body: some View {
		VStack(spacing: 0) {
			settingsSection
				.padding(20)
			Divider()
			toolbar
				.padding(.horizontal, 20)
				.padding(.vertical, 10)
			entryList
		}
		.onChange(of: saveAudio) { wasSaving, isSaving in
			if wasSaving && !isSaving && store.hasSavedRecordings {
				pendingPurge = .recordings
			}
		}
		.onAppear {
			store.reload()
			store.viewDidAppear()
		}
		.onDisappear {
			store.viewDidDisappear()
			player.stop()
		}
		.alert(
			"Delete older history?",
			isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
			presenting: pendingRetention
		) { change in
			Button("Delete", role: .destructive) { commitRetention(periodRaw: change.periodRaw, limit: change.limit) }
			Button("Cancel", role: .cancel) {}
		} message: { change in
			Text(
				"This deletes \(change.deletionCount) entries and their recordings now. Starred entries are kept."
			)
		}
		.alert(
			purgeTitle,
			isPresented: Binding(
				get: { activePurge != nil },
				set: {
					if !$0 {
						pendingPurge = nil
						store.keepEntriesAfterOptOut()
					}
				}),
			presenting: activePurge
		) { purge in
			Button("Delete", role: .destructive) {
				player.stop()
				switch purge {
				case .everything: store.deleteAllEntries()
				case .recordings: store.deleteAllRecordings()
				}
			}
			Button("Keep", role: .cancel) {}
		} message: { purge in
			switch purge {
			case .everything(let count):
				Text(
					"New dictations are no longer saved. Delete the \(count) entries already in history, including starred ones and their recordings?"
				)
			case .recordings:
				Text("New recordings are no longer saved. Delete the recordings already saved? The text of each entry is kept.")
			}
		}
		.alert(
			"History",
			isPresented: Binding(
				get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
			presenting: errorMessage
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
		.alert("Clear history?", isPresented: $showingClearConfirmation) {
			Button("Clear", role: .destructive) {
				player.stop()
				store.deleteAllUnstarred()
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Deletes every unstarred transcription and its recording. Starred entries are kept.")
		}
	}

	/// Turning history off is watched by the store, so the prompt appears whichever screen did it.
	private var activePurge: HistoryPurge? {
		pendingPurge ?? store.pendingOptOutPurge.map { .everything(count: $0) }
	}

	private var purgeTitle: String {
		switch activePurge {
		case .recordings: return String(localized: "Delete saved recordings?")
		default: return String(localized: "Delete saved history?")
		}
	}

	private var retentionSelection: Binding<String> {
		Binding(get: { retentionRaw }, set: { proposeRetention(periodRaw: $0, limit: historyLimit) })
	}

	private var limitSelection: Binding<Int> {
		Binding(get: { historyLimit }, set: { proposeRetention(periodRaw: retentionRaw, limit: $0) })
	}

	/// Retention deletes permanently, so a change that would remove entries asks first; the
	/// setting is only stored once confirmed.
	private func proposeRetention(periodRaw: String, limit: Int) {
		guard periodRaw != retentionRaw || limit != historyLimit else { return }
		let period = HistoryRetentionPeriod(rawValue: periodRaw) ?? HistorySettings.defaultRetention
		let count = store.retentionDeletionCount(period: period, limit: limit)
		if count == 0 {
			commitRetention(periodRaw: periodRaw, limit: limit)
		} else {
			pendingRetention = RetentionChange(periodRaw: periodRaw, limit: limit, deletionCount: count)
		}
	}

	private func commitRetention(periodRaw: String, limit: Int) {
		retentionRaw = periodRaw
		historyLimit = limit
		store.applyRetention()
	}

	private var settingsSection: some View {
		SettingsSection("History") {
			SettingRow("Save transcription history", description: "Keep each dictation so you can find it later")
			{
				Toggle("", isOn: $historyEnabled)
					.toggleStyle(.switch)
					.labelsHidden()
			}
			SettingRow(
				"Save recordings",
				description: "Keep the audio so entries can be replayed or re-transcribed. History and recordings stay on this Mac and are left out of Time Machine backups."
			) {
				Toggle("", isOn: $saveAudio)
					.toggleStyle(.switch)
					.labelsHidden()
			}
			.disabled(!historyEnabled)
			SettingRow("Delete entries after", description: "Starred entries are never deleted automatically") {
				Picker("", selection: retentionSelection) {
					ForEach(HistoryRetentionPeriod.allCases) { period in
						Text(period.displayName).tag(period.rawValue)
					}
				}
				.labelsHidden()
				.frame(width: 200)
			}
			if retentionRaw == HistoryRetentionPeriod.preserveLimit.rawValue {
				SettingRow("Entries to keep") {
					Stepper(
						"\(historyLimit)", value: limitSelection, in: HistorySettings.limitRange,
						step: historyLimit >= 100 ? 50 : 5)
				}
			}
		}
	}

	private var toolbar: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.foregroundColor(.secondary)
			TextField("Search transcriptions", text: $searchText)
				.textFieldStyle(.roundedBorder)
			Toggle(isOn: $starredOnly) {
				Image(systemName: starredOnly ? "star.fill" : "star")
			}
			.toggleStyle(.button)
			.help("Show starred only")
			Button("Clear") { showingClearConfirmation = true }
				.disabled(store.entries.allSatisfy(\.isStarred))
		}
	}

	@ViewBuilder
	private var entryList: some View {
		if filteredEntries.isEmpty {
			VStack(spacing: 8) {
				Image(systemName: "clock.arrow.circlepath")
					.font(.largeTitle)
					.foregroundColor(.secondary)
				Text(store.entries.isEmpty ? "No transcriptions yet" : "No matching transcriptions")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.padding(.vertical, 40)
		} else {
			List(filteredEntries, id: \.id) { entry in
				HistoryEntryRow(
					entry: entry,
					hasAudio: store.audioURL(for: entry) != nil,
					isPlaying: player.playingID == entry.id,
					isRetranscribing: store.retranscribingIDs.contains(entry.id),
					justCopied: copiedID == entry.id,
					canPostProcess: postProcessingEnabled,
					onPlay: { play(entry) },
					onCopy: { copy(entry.text, id: entry.id) },
					onCopyOriginal: { copy(entry.transcriptText, id: entry.id) },
					onPostProcess: { reprocess(entry) },
					onStar: { store.toggleStar(entry) },
					onRetranscribe: { retranscribe(entry) },
					onReveal: { reveal(entry) },
					onDelete: {
						if player.playingID == entry.id { player.stop() }
						store.delete(entry)
					}
				)
			}
			.listStyle(.inset)
		}
	}

	private func play(_ entry: TranscriptionHistoryEntry) {
		guard let url = store.audioURL(for: entry) else {
			errorMessage = TranscriptionHistoryError.audioUnavailable.localizedDescription
			return
		}
		player.toggle(id: entry.id, url: url)
	}

	private func copy(_ text: String, id: UUID) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		copiedID = id
		Task {
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			if copiedID == id { copiedID = nil }
		}
	}

	private func retranscribe(_ entry: TranscriptionHistoryEntry) {
		Task {
			do {
				try await store.retranscribe(entry)
			} catch {
				errorMessage = String(localized: "Re-transcription failed: \(error.localizedDescription)")
			}
		}
	}

	private func reprocess(_ entry: TranscriptionHistoryEntry) {
		Task {
			do {
				try await store.reprocess(entry)
			} catch {
				errorMessage = String(localized: "Post-processing failed: \(error.localizedDescription)")
			}
		}
	}

	private func reveal(_ entry: TranscriptionHistoryEntry) {
		guard let url = store.audioURL(for: entry) else { return }
		NSWorkspace.shared.activateFileViewerSelecting([url])
	}
}

private struct HistoryEntryRow: View {
	let entry: TranscriptionHistoryEntry
	let hasAudio: Bool
	let isPlaying: Bool
	let isRetranscribing: Bool
	let justCopied: Bool
	let canPostProcess: Bool
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onCopyOriginal: () -> Void
	let onPostProcess: () -> Void
	let onStar: () -> Void
	let onRetranscribe: () -> Void
	let onReveal: () -> Void
	let onDelete: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: entry.source.systemImage)
					.foregroundColor(.secondary)
				Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
				if entry.durationSeconds > 0 {
					Text(Self.formatDuration(entry.durationSeconds))
				}
				if let model = entry.modelName {
					Text(WhisperKitTranscriber.getModelDisplayName(for: model))
						.lineLimit(1)
				}
				Spacer()
				actions
			}
			.font(.caption)
			.foregroundColor(.secondary)

			if isRetranscribing {
				HStack(spacing: 6) {
					ProgressView().controlSize(.small)
					Text("Re-transcribing...").font(.caption).foregroundColor(.secondary)
				}
			} else if let error = entry.errorMessage {
				Label("Transcription failed: \(error)", systemImage: "exclamationmark.triangle")
					.font(.caption)
					.foregroundColor(.orange)
			}

			if !entry.text.isEmpty {
				Text(entry.text)
					.textSelection(.enabled)
					.lineLimit(6)
			}

			if entry.postProcessRequested {
				postProcessingDetails
			}
		}
		.padding(.vertical, 4)
		.contextMenu {
			Button("Copy", action: onCopy).disabled(entry.text.isEmpty)
			if entry.rawText != nil {
				Button("Copy Original Transcript", action: onCopyOriginal)
			}
			Button(entry.isStarred ? "Unstar" : "Star", action: onStar)
			Button(entry.didFail ? "Retry" : "Re-transcribe", action: onRetranscribe)
				.disabled(!hasAudio || isRetranscribing)
			Button("Post-process Again", action: onPostProcess)
				.disabled(!canPostProcess || entry.transcriptText.isEmpty || isRetranscribing)
			Button("Show Recording in Finder", action: onReveal).disabled(!hasAudio)
			Divider()
			Button("Delete", role: .destructive, action: onDelete)
		}
	}

	@ViewBuilder
	private var postProcessingDetails: some View {
		if let error = entry.postProcessError {
			Label("Post-processing failed: \(error)", systemImage: "exclamationmark.triangle")
				.font(.caption)
				.foregroundColor(.orange)
		}
		if let raw = entry.rawText, raw != entry.text {
			DisclosureGroup {
				Text(raw)
					.textSelection(.enabled)
					.lineLimit(6)
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			} label: {
				Label(
					"Original transcript, post-processed with \(entry.postProcessPromptName ?? "")",
					systemImage: "wand.and.stars"
				)
				.font(.caption)
				.foregroundColor(.secondary)
			}
			.help(entry.postProcessPrompt ?? "")
		}
	}

	private var actions: some View {
		HStack(spacing: 10) {
			Button(action: onPlay) {
				Image(systemName: isPlaying ? "stop.fill" : "play.fill")
			}
			.disabled(!hasAudio)
			.help(isPlaying ? "Stop" : "Play recording")

			Button(action: onCopy) {
				Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
			}
			.disabled(entry.text.isEmpty)
			.help("Copy text")

			Button(action: onStar) {
				Image(systemName: entry.isStarred ? "star.fill" : "star")
					.foregroundColor(entry.isStarred ? .yellow : nil)
			}
			.help(entry.isStarred ? "Unstar" : "Star (kept forever)")

			Button(action: onRetranscribe) {
				Image(systemName: "arrow.clockwise")
			}
			.disabled(!hasAudio || isRetranscribing)
			.help(entry.didFail ? "Retry transcription" : "Re-transcribe with the current model")

			Button(action: onDelete) {
				Image(systemName: "trash")
			}
			.help("Delete")
		}
		.buttonStyle(.borderless)
	}

	static func formatDuration(_ seconds: Double) -> String {
		let total = Int(seconds.rounded())
		return String(format: "%d:%02d", total / 60, total % 60)
	}
}
