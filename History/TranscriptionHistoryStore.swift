import AVFoundation
import Foundation
import SQLite3
import SwiftData

enum TranscriptionHistoryAudio {
	case samples([Float], sampleRate: Int)
	/// The file is moved into the history folder, so callers must not rely on it afterwards.
	case file(URL)
}

enum TranscriptionHistoryError: LocalizedError {
	case audioUnavailable
	case storeUnavailable
	case nothingToPostProcess

	var errorDescription: String? {
		switch self {
		case .audioUnavailable: return String(localized: "The recording for this entry is no longer available.")
		case .storeUnavailable: return String(localized: "Transcription history could not be opened.")
		case .nothingToPostProcess: return String(localized: "This entry has no transcript to post-process.")
		}
	}
}

@MainActor
@Observable
final class TranscriptionHistoryStore {
	typealias PostProcessor = @Sendable (String) async -> HistoryPostProcessing

	/// History's LLM pass is the Clean up recipe.
	static let livePostProcessor: PostProcessor = { transcript in
		await DictationCoordinator.shared.cleanUpForHistory(transcript)
	}

	static let shared = TranscriptionHistoryStore(
		directory: TranscriptionHistoryStore.defaultDirectory(), defaults: .standard,
		presentOptOutPrompt: { HistoryWindowController.shared.show() })

	private(set) var entries: [TranscriptionHistoryEntry] = []
	private(set) var retranscribingIDs: Set<UUID> = []
	/// Set when history is turned off, from any settings screen or `defaults`, while entries
	/// remain; the history view asks whether to delete them.
	private(set) var pendingOptOutPurge: Int?

	@ObservationIgnored let audioDirectory: URL
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let now: () -> Date
	@ObservationIgnored private let container: ModelContainer?
	/// Why history is not using its normal database, for the history window to tell the user once.
	private(set) var storeNotice: String?
	@ObservationIgnored private var context: ModelContext? { container?.mainContext }
	@ObservationIgnored private var pendingAudioWrites: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored let storeURL: URL
	@ObservationIgnored private var scrubTask: Task<Void, Never>?
	@ObservationIgnored private var enabledObserver: DefaultsKeyObserver?
	@ObservationIgnored private var wasEnabled: Bool
	@ObservationIgnored private let presentOptOutPrompt: @MainActor () -> Void
	/// History views on screen; when none is, turning history off opens the window to ask.
	@ObservationIgnored private var visibleViews = 0

	init(
		directory: URL, defaults: UserDefaults, now: @escaping () -> Date = Date.init,
		presentOptOutPrompt: @escaping @MainActor () -> Void = {}
	) {
		self.audioDirectory = directory.appendingPathComponent("Recordings", isDirectory: true)
		self.storeURL = directory.appendingPathComponent("history.store")
		self.defaults = defaults
		self.now = now
		self.presentOptOutPrompt = presentOptOutPrompt
		self.wasEnabled = HistorySettings(defaults: defaults).isEnabled

		do {
			try FileManager.default.createDirectory(
				at: audioDirectory, withIntermediateDirectories: true)
			// The whole folder, so the transcript database and its -wal/-shm stay out of backups too
			Self.excludeFromBackup(directory)
			Self.excludeFromBackup(audioDirectory)
		} catch {
			AppLogger.shared.database.error("Failed to create the history folder: \(error)")
		}
		let opened = Self.openContainer(at: storeURL)
		container = opened.0
		storeNotice = opened.1
		reload()
		applyRetention(userInitiated: false)
		// Retention deletes from a previous run that were never scrubbed
		if retentionDeletesAwaitingScrub > 0 {
			scheduleScrub()
		}
		enabledObserver = DefaultsKeyObserver(defaults: defaults, keys: [HistorySettings.enabledKey]) {
			[weak self] in self?.historyEnabledChanged()
		}
	}

	/// A store that will not open (corrupt file, schema it cannot read) is moved aside and history
	/// starts fresh, instead of every dictation silently going unrecorded until the user notices.
	/// When even a fresh store fails, history lives in memory for this session.
	static func openContainer(at storeURL: URL) -> (ModelContainer?, String?) {
		func open() throws -> ModelContainer {
			try ModelContainer(
				for: TranscriptionHistoryEntry.self, configurations: ModelConfiguration(url: storeURL))
		}
		let firstError: Error
		do {
			return (try open(), nil)
		} catch {
			firstError = error
			AppLogger.shared.database.error("Failed to open transcription history: \(error)")
		}

		// A full disk is not damage; moving the database aside would only hide the user's history
		if !isOutOfSpace(firstError), let kept = quarantineStore(at: storeURL) {
			do {
				let container = try open()
				AppLogger.shared.database.info("Started a new history database; the old one is at \(kept.path)")
				return (
					container,
					String(
						localized:
							"Your transcription history could not be opened, so Whispera started a new one. The old history was kept as \(kept.lastPathComponent) in the History folder."
					)
				)
			} catch {
				AppLogger.shared.database.error("A new history database also failed to open: \(error)")
			}
		}

		do {
			let memory = try ModelContainer(
				for: TranscriptionHistoryEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
			return (
				memory,
				String(
					localized:
						"Transcription history could not be saved to disk (\(firstError.localizedDescription)). This session's dictations are kept until Whispera quits."
				)
			)
		} catch {
			AppLogger.shared.database.error("In-memory history also failed: \(error)")
			return (nil, TranscriptionHistoryError.storeUnavailable.localizedDescription)
		}
	}

	static let quarantinePrefix = "history-unreadable-"

	/// Moves the database and its -wal/-shm companions to a timestamped name next to it.
	static func quarantineStore(at storeURL: URL) -> URL? {
		let fileManager = FileManager.default
		let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
		let kept = storeURL.deletingLastPathComponent().appendingPathComponent("\(quarantinePrefix)\(stamp).store")
		var movedAny = false
		for suffix in ["", "-wal", "-shm"] {
			let source = URL(fileURLWithPath: storeURL.path + suffix)
			guard fileManager.fileExists(atPath: source.path) else { continue }
			do {
				try fileManager.moveItem(at: source, to: URL(fileURLWithPath: kept.path + suffix))
				movedAny = true
			} catch {
				AppLogger.shared.database.error("Could not move \(source.lastPathComponent) aside: \(error)")
				return nil
			}
		}
		return movedAny ? kept : nil
	}

	/// When a store was set aside, from its name. The file's own dates are those of the old
	/// database, which may be far older than the move.
	static func quarantineDate(fileName: String) -> Date? {
		guard fileName.hasPrefix(quarantinePrefix), let storeRange = fileName.range(of: ".store") else { return nil }
		let stamp = fileName[fileName.index(fileName.startIndex, offsetBy: quarantinePrefix.count)..<storeRange.lowerBound]
		let parts = stamp.split(separator: "T", maxSplits: 1)
		guard parts.count == 2 else { return nil }
		return ISO8601DateFormatter().date(from: "\(parts[0])T\(parts[1].replacingOccurrences(of: "-", with: ":"))")
	}

	static func isOutOfSpace(_ error: Error) -> Bool {
		var current: NSError? = error as NSError
		while let nsError = current {
			if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return true }
			if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { return true }
			// SQLITE_FULL
			if nsError.userInfo["NSSQLiteErrorDomain"] as? Int == 13 { return true }
			current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
		}
		return false
	}

	/// The history window shows this once.
	func acknowledgeStoreNotice() -> String? {
		defer { storeNotice = nil }
		return storeNotice
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
		errorMessage: String? = nil,
		postProcessing: HistoryPostProcessing? = nil,
		postProcessRequested: Bool = false
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
		entry.apply(transcript: trimmed, postProcessing: postProcessing)
		// A failed transcription never reached post-processing but must remember it was asked for
		if postProcessRequested {
			entry.postProcessRequested = true
		}
		context.insert(entry)
		guard save() else {
			if let audioFileName {
				try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(audioFileName))
			}
			return nil
		}
		entries.insert(entry, at: 0)
		applyRetention(userInitiated: false)
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

	/// Removes every entry, starred ones included, with its recording, and any database that was
	/// set aside as unreadable, since that holds older dictations too.
	func deleteAllEntries() {
		pendingOptOutPurge = nil
		remove(entries)
		removeOrphanedAudio()
		removeQuarantinedStores(olderThan: nil)
	}

	func keepEntriesAfterOptOut() {
		pendingOptOutPurge = nil
	}

	func viewDidAppear() {
		visibleViews += 1
	}

	func viewDidDisappear() {
		visibleViews = max(visibleViews - 1, 0)
	}

	private func historyEnabledChanged() {
		let isEnabled = settings.isEnabled
		defer { wasEnabled = isEnabled }
		guard wasEnabled, !isEnabled else {
			if isEnabled { pendingOptOutPurge = nil }
			return
		}
		guard !entries.isEmpty else {
			// Nothing to ask about: Whispera cannot read or show what is set aside, and the user
			// has just said they want no history kept
			removeQuarantinedStores(olderThan: nil)
			return
		}
		pendingOptOutPurge = entries.count
		if visibleViews == 0 {
			presentOptOutPrompt()
		}
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
		_ text: String, modelName: String?, language: String?, to entry: TranscriptionHistoryEntry,
		postProcessing: HistoryPostProcessing? = nil
	) {
		entry.apply(transcript: text, postProcessing: postProcessing)
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

	/// Re-runs the speech model on the saved recording. `postProcess` defaults to whatever the
	/// original dictation asked for, so a retried post-processed dictation is post-processed again.
	func retranscribe(
		_ entry: TranscriptionHistoryEntry,
		transcriber: WhisperKitTranscriber? = nil,
		enableTranslation: Bool? = nil,
		postProcess: Bool? = nil,
		postProcessor: PostProcessor? = nil
	) async throws {
		let transcriber = transcriber ?? .shared
		let enableTranslation = enableTranslation ?? defaults.bool(forKey: "enableTranslation")
		try await retranscribe(entry, postProcess: postProcess, postProcessor: postProcessor) { url in
			let text = try await transcriber.transcribe(audioURL: url, enableTranslation: enableTranslation)
			return (text, transcriber.currentModel ?? transcriber.selectedModel)
		}
	}

	func retranscribe(
		_ entry: TranscriptionHistoryEntry,
		postProcess: Bool? = nil,
		postProcessor: PostProcessor? = nil,
		using transcribe: (URL) async throws -> (text: String, modelName: String?)
	) async throws {
		let postProcess = postProcess ?? entry.postProcessRequested
		guard let url = audioURL(for: entry) else { throw TranscriptionHistoryError.audioUnavailable }
		let id = entry.id
		guard !retranscribingIDs.contains(id) else { return }

		retranscribingIDs.insert(id)
		defer { retranscribingIDs.remove(id) }

		do {
			let result = try await transcribe(url)
			var postProcessing: HistoryPostProcessing?
			if postProcess {
				postProcessing = await (postProcessor ?? Self.livePostProcessor)(result.text)
			}
			// Retention or the user may have deleted the entry while it was transcribing, and
			// writing to a deleted SwiftData model can trap.
			guard let live = liveEntry(id) else {
				AppLogger.shared.database.info("History entry \(id) was deleted during re-transcription")
				return
			}
			applyTranscription(
				result.text, modelName: result.modelName,
				language: defaults.string(forKey: "selectedLanguage"), to: live,
				postProcessing: postProcessing)
			AppLogger.shared.database.info("Re-transcribed history entry \(id)")
		} catch {
			AppLogger.shared.database.error("Re-transcription failed: \(error.localizedDescription)")
			if let live = liveEntry(id) {
				markFailed(live, message: error.localizedDescription)
			}
			throw error
		}
	}

	/// Runs Clean up again over the speech model's original output, without re-transcribing.
	/// Useful after changing the prompt or server, and works for entries without audio.
	func reprocess(_ entry: TranscriptionHistoryEntry, postProcessor: PostProcessor? = nil) async throws {
		let transcript = entry.transcriptText
		guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw TranscriptionHistoryError.nothingToPostProcess
		}
		let id = entry.id
		guard !retranscribingIDs.contains(id) else { return }

		retranscribingIDs.insert(id)
		defer { retranscribingIDs.remove(id) }

		let postProcessing = await (postProcessor ?? Self.livePostProcessor)(transcript)
		guard let live = liveEntry(id) else {
			AppLogger.shared.database.info("History entry \(id) was deleted during post-processing")
			return
		}
		live.apply(transcript: transcript, postProcessing: postProcessing)
		live.retranscribedAt = now()
		save()
		AppLogger.shared.database.info("Re-ran Clean up for history entry \(id)")
	}

	private func liveEntry(_ id: UUID) -> TranscriptionHistoryEntry? {
		entries.first { $0.id == id && !$0.isDeleted && $0.modelContext != nil }
	}

	// MARK: - Retention

	/// Deleted rows stay in SQLite's free pages until a scrub rewrites the file. Pruning after a
	/// dictation usually removes one entry, and a full rewrite for each would cost a VACUUM per
	/// dictation, so those are scrubbed in batches. A user-initiated delete is scrubbed right away.
	static let retentionScrubBatch = 25
	static let retentionScrubPendingKey = "historyRetentionDeletesAwaitingScrub"

	/// Scrubs requested so far, for tests.
	@ObservationIgnored private(set) var scrubsScheduled = 0

	var retentionDeletesAwaitingScrub: Int {
		get { defaults.integer(forKey: Self.retentionScrubPendingKey) }
		set { defaults.set(newValue, forKey: Self.retentionScrubPendingKey) }
	}

	func applyRetention(userInitiated: Bool = true) {
		guard context != nil else { return }
		let settings = self.settings
		if let cutoff = Self.quarantineCutoff(settings: settings, liveEntryCount: entries.count, now: now()) {
			removeQuarantinedStores(olderThan: cutoff)
		}
		let doomed = idsToDelete(period: settings.retention, limit: settings.limit)
		guard !doomed.isEmpty else { return }

		if userInitiated {
			remove(entries.filter { doomed.contains($0.id) })
		} else {
			remove(entries.filter { doomed.contains($0.id) }, scrub: false)
			retentionDeletesAwaitingScrub += doomed.count
			if retentionDeletesAwaitingScrub >= Self.retentionScrubBatch {
				scheduleScrub()
			}
		}
		AppLogger.shared.database.info("History retention removed \(doomed.count) entries")
	}

	/// When retention should drop databases set aside as unreadable, or nil to keep them. Every
	/// dictation in one is older than the live history, so with count-only retention they go once
	/// the live history is full: the newest `limit` entries are all newer than them.
	nonisolated static func quarantineCutoff(settings: HistorySettings, liveEntryCount: Int, now: Date) -> Date? {
		if let maxAge = settings.retention.maxAge {
			return now.addingTimeInterval(-maxAge)
		}
		if settings.retention == .preserveLimit, liveEntryCount >= settings.limit {
			return .distantFuture
		}
		return nil
	}

	/// Databases moved aside as unreadable still hold old dictations. With `cutoff` nil every one
	/// goes; otherwise only those set aside before it.
	func removeQuarantinedStores(olderThan cutoff: Date?) {
		let directory = storeURL.deletingLastPathComponent()
		let fileManager = FileManager.default
		guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
		for name in names where name.hasPrefix(Self.quarantinePrefix) {
			let url = directory.appendingPathComponent(name)
			if let cutoff {
				guard let setAside = Self.quarantineDate(fileName: name), setAside < cutoff else { continue }
			}
			do {
				try fileManager.removeItem(at: url)
				AppLogger.shared.database.info("Removed the set-aside history file \(name)")
			} catch {
				AppLogger.shared.database.error("Could not remove \(name): \(error)")
			}
		}
	}

	/// How many entries switching to these retention settings would delete right away, so the
	/// change can be confirmed first.
	func retentionDeletionCount(period: HistoryRetentionPeriod, limit: Int) -> Int {
		guard context != nil else { return 0 }
		return idsToDelete(period: period, limit: limit).count
	}

	private func idsToDelete(period: HistoryRetentionPeriod, limit: Int) -> Set<UUID> {
		HistoryRetention.idsToDelete(
			from: entries.map {
				HistoryRetentionCandidate(id: $0.id, createdAt: $0.createdAt, isStarred: $0.isStarred)
			},
			period: period,
			limit: limit,
			now: now()
		)
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
				&& (needle.isEmpty || entry.text.localizedCaseInsensitiveContains(needle)
					|| (entry.rawText?.localizedCaseInsensitiveContains(needle) ?? false))
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
	private func remove(_ doomed: [TranscriptionHistoryEntry], scrub: Bool = true) {
		guard !doomed.isEmpty else { return }
		let ids = Set(doomed.map(\.id))
		entries.removeAll { ids.contains($0.id) }
		for entry in doomed {
			removeAudio(for: entry)
			context?.delete(entry)
		}
		save()
		if scrub {
			scheduleScrub()
		}
	}

	// MARK: - Scrubbing deleted text

	/// SQLite leaves deleted rows in free pages and in the write-ahead log until they are reused,
	/// so a "deleted" dictation stays recoverable from the file. Coalesced so a burst of deletes
	/// rewrites the file once.
	private func scheduleScrub() {
		scrubTask?.cancel()
		scrubsScheduled += 1
		let url = storeURL
		scrubTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 500_000_000)
			guard !Task.isCancelled else { return }
			let covered = self?.retentionDeletesAwaitingScrub ?? 0
			let scrubbed = await Task.detached(priority: .utility) { Self.scrub(storeAt: url) }.value
			if scrubbed, let self {
				self.retentionDeletesAwaitingScrub = max(self.retentionDeletesAwaitingScrub - covered, 0)
			}
		}
	}

	/// Waits for a pending scrub, for tests and for callers that must know the text is gone.
	func flushScrub() async {
		await scrubTask?.value
	}

	/// Rewrites the database without its free pages and empties the write-ahead log.
	@discardableResult
	nonisolated static func scrub(storeAt url: URL) -> Bool {
		guard FileManager.default.fileExists(atPath: url.path) else { return false }
		var db: OpaquePointer?
		guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
			AppLogger.shared.database.error("Could not open history to scrub deleted entries")
			sqlite3_close(db)
			return false
		}
		defer { sqlite3_close(db) }
		sqlite3_busy_timeout(db, 5000)
		for statement in ["PRAGMA secure_delete = ON", "VACUUM", "PRAGMA wal_checkpoint(TRUNCATE)"] {
			guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
				let message = String(cString: sqlite3_errmsg(db))
				AppLogger.shared.database.error("History scrub step '\(statement)' failed: \(message)")
				return false
			}
		}
		return true
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
			AppLogger.shared.database.error("Could not exclude history from backups: \(error)")
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
