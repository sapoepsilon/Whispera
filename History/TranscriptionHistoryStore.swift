import AVFoundation
import Foundation
import SwiftData

enum TranscriptionHistoryAudio {
	case samples([Float], sampleRate: Int)
	/// The file is moved into the history folder, so callers must not rely on it afterwards.
	case file(URL)
}

enum TranscriptionHistoryError: LocalizedError {
	case audioUnavailable
	case storeUnavailable

	var errorDescription: String? {
		switch self {
		case .audioUnavailable: return "The recording for this entry is no longer available."
		case .storeUnavailable: return "Transcription history could not be opened."
		}
	}
}

@MainActor
@Observable
final class TranscriptionHistoryStore {
	static let shared = TranscriptionHistoryStore(
		directory: TranscriptionHistoryStore.defaultDirectory(), defaults: .standard)

	private(set) var entries: [TranscriptionHistoryEntry] = []
	private(set) var retranscribingIDs: Set<UUID> = []

	@ObservationIgnored let audioDirectory: URL
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let now: () -> Date
	@ObservationIgnored private let container: ModelContainer?
	@ObservationIgnored private var context: ModelContext? { container?.mainContext }
	@ObservationIgnored private var pendingAudioWrites: [UUID: Task<Void, Never>] = [:]

	init(directory: URL, defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
		self.audioDirectory = directory.appendingPathComponent("Recordings", isDirectory: true)
		self.defaults = defaults
		self.now = now

		do {
			try FileManager.default.createDirectory(
				at: audioDirectory, withIntermediateDirectories: true)
			Self.excludeFromBackup(audioDirectory)
			let configuration = ModelConfiguration(
				url: directory.appendingPathComponent("history.store"))
			container = try ModelContainer(
				for: TranscriptionHistoryEntry.self, configurations: configuration)
		} catch {
			container = nil
			AppLogger.shared.database.error("Failed to open transcription history: \(error)")
		}

		reload()
		applyRetention()
	}

	static func defaultDirectory() -> URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera", isDirectory: true)
			.appendingPathComponent("History", isDirectory: true)
	}

	var settings: HistorySettings {
		HistorySettings(defaults: defaults)
	}

	// MARK: - Recording

	@discardableResult
	func record(
		text: String,
		audio: TranscriptionHistoryAudio?,
		source: TranscriptionHistorySource,
		modelName: String?,
		language: String?,
		errorMessage: String? = nil
	) -> TranscriptionHistoryEntry? {
		let settings = self.settings
		guard settings.isEnabled, let context else { return nil }

		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty || errorMessage != nil else { return nil }

		let id = UUID()
		var audioFileName: String?
		var duration: TimeInterval = 0

		if let audio {
			duration = Self.duration(of: audio)
			if settings.savesAudio {
				audioFileName = persistAudio(audio, id: id)
			}
		}

		let entry = TranscriptionHistoryEntry(
			id: id,
			createdAt: now(),
			text: trimmed,
			audioFileName: audioFileName,
			durationSeconds: duration,
			modelName: modelName,
			language: language,
			source: source,
			errorMessage: errorMessage
		)
		context.insert(entry)
		guard save() else {
			if let audioFileName {
				try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(audioFileName))
			}
			return nil
		}
		entries.insert(entry, at: 0)
		applyRetention()
		return entries.contains(where: { $0.id == id }) ? entry : nil
	}

	// MARK: - Mutations

	/// Retention is not applied here, so unstarring an old entry never deletes it on the spot; the
	/// next dictation or launch prunes it.
	func toggleStar(_ entry: TranscriptionHistoryEntry) {
		entry.isStarred.toggle()
		save()
	}

	func delete(_ entry: TranscriptionHistoryEntry) {
		remove([entry])
	}

	/// Starred entries survive, matching the retention exemption.
	func deleteAllUnstarred() {
		remove(entries.filter { !$0.isStarred })
	}

	/// Removes every entry, starred ones included, with its recording.
	func deleteAllEntries() {
		remove(entries)
		removeOrphanedAudio()
	}

	/// Drops every saved recording but keeps the text of each entry.
	func deleteAllRecordings() {
		for entry in entries where entry.audioFileName != nil {
			removeAudio(for: entry)
			entry.audioFileName = nil
		}
		save()
		removeOrphanedAudio()
	}

	var hasSavedRecordings: Bool {
		entries.contains { $0.audioFileName != nil }
	}

	/// Waits for background WAV writes started by `record`.
	func flushPendingAudioWrites() async {
		for task in Array(pendingAudioWrites.values) {
			await task.value
		}
	}

	func audioURL(for entry: TranscriptionHistoryEntry) -> URL? {
		guard let name = entry.audioFileName else { return nil }
		let url = audioDirectory.appendingPathComponent(name)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	func applyTranscription(
		_ text: String, modelName: String?, language: String?, to entry: TranscriptionHistoryEntry
	) {
		entry.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		entry.errorMessage = nil
		entry.modelName = modelName
		entry.language = language
		entry.retranscribedAt = now()
		save()
	}

	func markFailed(_ entry: TranscriptionHistoryEntry, message: String) {
		entry.errorMessage = message
		save()
	}

	func retranscribe(
		_ entry: TranscriptionHistoryEntry,
		transcriber: WhisperKitTranscriber? = nil,
		enableTranslation: Bool? = nil
	) async throws {
		let transcriber = transcriber ?? .shared
		let enableTranslation = enableTranslation ?? defaults.bool(forKey: "enableTranslation")
		try await retranscribe(entry) { url in
			let text = try await transcriber.transcribe(audioURL: url, enableTranslation: enableTranslation)
			return (text, transcriber.currentModel ?? transcriber.selectedModel)
		}
	}

	func retranscribe(
		_ entry: TranscriptionHistoryEntry,
		using transcribe: (URL) async throws -> (text: String, modelName: String?)
	) async throws {
		guard let url = audioURL(for: entry) else { throw TranscriptionHistoryError.audioUnavailable }
		let id = entry.id
		guard !retranscribingIDs.contains(id) else { return }

		retranscribingIDs.insert(id)
		defer { retranscribingIDs.remove(id) }

		do {
			let result = try await transcribe(url)
			// Retention or the user may have deleted the entry while it was transcribing, and
			// writing to a deleted SwiftData model can trap.
			guard let live = liveEntry(id) else {
				AppLogger.shared.database.info("History entry \(id) was deleted during re-transcription")
				return
			}
			applyTranscription(
				result.text, modelName: result.modelName,
				language: defaults.string(forKey: "selectedLanguage"), to: live)
			AppLogger.shared.database.info("Re-transcribed history entry \(id)")
		} catch {
			AppLogger.shared.database.error("Re-transcription failed: \(error.localizedDescription)")
			if let live = liveEntry(id) {
				markFailed(live, message: error.localizedDescription)
			}
			throw error
		}
	}

	private func liveEntry(_ id: UUID) -> TranscriptionHistoryEntry? {
		entries.first { $0.id == id && !$0.isDeleted && $0.modelContext != nil }
	}

	// MARK: - Retention

	func applyRetention() {
		guard context != nil else { return }
		let settings = self.settings
		let doomed = HistoryRetention.idsToDelete(
			from: entries.map {
				HistoryRetentionCandidate(id: $0.id, createdAt: $0.createdAt, isStarred: $0.isStarred)
			},
			period: settings.retention,
			limit: settings.limit,
			now: now()
		)
		guard !doomed.isEmpty else { return }

		remove(entries.filter { doomed.contains($0.id) })
		AppLogger.shared.database.info("History retention removed \(doomed.count) entries")
	}

	func reload() {
		guard let context else {
			entries = []
			return
		}
		let descriptor = FetchDescriptor<TranscriptionHistoryEntry>(
			sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
		do {
			entries = try context.fetch(descriptor)
		} catch {
			entries = []
			AppLogger.shared.database.error("Failed to load transcription history: \(error)")
		}
	}

	static func filter(
		_ entries: [TranscriptionHistoryEntry], query: String, starredOnly: Bool
	) -> [TranscriptionHistoryEntry] {
		let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
		return entries.filter { entry in
			(!starredOnly || entry.isStarred)
				&& (needle.isEmpty || entry.text.localizedCaseInsensitiveContains(needle))
		}
	}

	// MARK: - Private

	// A failed save (for example a full disk) leaves unsaved changes that make the next delete throw
	@discardableResult
	private func save() -> Bool {
		do {
			try context?.save()
			return true
		} catch {
			AppLogger.shared.database.error("Failed to save transcription history: \(error)")
			context?.rollback()
			reload()
			return false
		}
	}

	/// Detach from the published list before deleting so no view reads a deleted model.
	private func remove(_ doomed: [TranscriptionHistoryEntry]) {
		guard !doomed.isEmpty else { return }
		let ids = Set(doomed.map(\.id))
		entries.removeAll { ids.contains($0.id) }
		for entry in doomed {
			removeAudio(for: entry)
			context?.delete(entry)
		}
		save()
	}

	private func persistAudio(_ audio: TranscriptionHistoryAudio, id: UUID) -> String? {
		let name = "\(id.uuidString).wav"
		let destination = audioDirectory.appendingPathComponent(name)
		do {
			switch audio {
			case .samples(let samples, let sampleRate):
				guard !samples.isEmpty else { return nil }
				writeAudioInBackground(samples, sampleRate: sampleRate, to: destination, id: id, name: name)
			case .file(let url):
				try FileManager.default.moveItem(at: url, to: destination)
			}
			return name
		} catch {
			AppLogger.shared.database.error("Failed to save history audio: \(error)")
			return nil
		}
	}

	/// A long session is tens of MB of PCM, so encoding and writing stay off the main actor.
	private func writeAudioInBackground(
		_ samples: [Float], sampleRate: Int, to destination: URL, id: UUID, name: String
	) {
		pendingAudioWrites[id] = Task { [weak self] in
			let succeeded = await Task.detached(priority: .utility) {
				do {
					try WAVFileWriter.write(samples: samples, sampleRate: sampleRate, to: destination)
					return true
				} catch {
					AppLogger.shared.database.error("Failed to save history audio: \(error)")
					return false
				}
			}.value
			self?.finishAudioWrite(id: id, name: name, destination: destination, succeeded: succeeded)
		}
	}

	private func finishAudioWrite(id: UUID, name: String, destination: URL, succeeded: Bool) {
		pendingAudioWrites[id] = nil
		guard let entry = liveEntry(id), entry.audioFileName == name else {
			// The entry or its recording was deleted while the file was being written.
			try? FileManager.default.removeItem(at: destination)
			return
		}
		if !succeeded {
			entry.audioFileName = nil
			save()
		}
	}

	/// Catches files whose entry is gone, e.g. from a write that finished after a delete.
	private func removeOrphanedAudio() {
		let referenced = Set(entries.compactMap(\.audioFileName))
		let pending = Set(pendingAudioWrites.keys.map { "\($0.uuidString).wav" })
		guard
			let files = try? FileManager.default.contentsOfDirectory(
				at: audioDirectory, includingPropertiesForKeys: nil)
		else { return }
		for file in files where !referenced.contains(file.lastPathComponent) && !pending.contains(file.lastPathComponent) {
			try? FileManager.default.removeItem(at: file)
		}
	}

	private static func excludeFromBackup(_ directory: URL) {
		var url = directory
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		do {
			try url.setResourceValues(values)
		} catch {
			AppLogger.shared.database.error("Could not exclude history recordings from backups: \(error)")
		}
	}

	private func removeAudio(for entry: TranscriptionHistoryEntry) {
		guard let name = entry.audioFileName else { return }
		try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(name))
	}

	private static func duration(of audio: TranscriptionHistoryAudio) -> TimeInterval {
		switch audio {
		case .samples(let samples, let sampleRate):
			return sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
		case .file(let url):
			guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0
			else { return 0 }
			return Double(file.length) / file.fileFormat.sampleRate
		}
	}
}
