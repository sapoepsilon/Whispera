import Foundation
import Observation

/// A dictation the user cancelled (Escape, the pill, a remote cancel) whose audio was kept so an
/// accidental cancel can be transcribed after all.
struct CancelledRecording: Codable, Identifiable, Equatable, Sendable {
	let id: UUID
	let createdAt: Date
	let durationSeconds: Double
	let fileName: String
}

/// Keeps the last few cancelled recordings as 16 kHz mono WAV files under
/// Application Support/Whispera/CancelledRecordings. The list lives in UserDefaults; the files
/// are the source of truth for whether a recording can still be transcribed.
@MainActor
@Observable
final class CancelledRecordingStore {
	nonisolated static let minimumDuration: TimeInterval = 0.5
	nonisolated static let defaultMaxCount = 10
	nonisolated static let defaultMaxAge: TimeInterval = 24 * 60 * 60
	nonisolated static let indexKey = "cancelledRecordings"
	nonisolated static let keepRecordingsKey = "keepCancelledRecordings"
	nonisolated static let defaultKeepRecordings = true
	/// Cancelled audio can hold anything said near the mic, so only this user may read it.
	nonisolated static let directoryPermissions: Int = 0o700
	nonisolated static let filePermissions: Int = 0o600

	static let shared = CancelledRecordingStore(directory: defaultDirectory(), defaults: .standard)

	/// Newest first.
	private(set) var recordings: [CancelledRecording] = []
	/// The recording being transcribed right now, if any.
	private(set) var transcribingID: UUID?

	@ObservationIgnored let directory: URL
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let now: () -> Date
	@ObservationIgnored let maxCount: Int
	@ObservationIgnored let maxAge: TimeInterval
	@ObservationIgnored private var transcriptionTask: Task<String, Error>?
	/// Tells a finishing run whether it is still the current one after a cancel and a new start.
	@ObservationIgnored private var transcriptionToken: UUID?
	/// Files still being written, which pruning must not mistake for strays.
	@ObservationIgnored private var pendingFileNames: Set<String> = []

	init(
		directory: URL, defaults: UserDefaults, now: @escaping () -> Date = Date.init,
		maxCount: Int = CancelledRecordingStore.defaultMaxCount,
		maxAge: TimeInterval = CancelledRecordingStore.defaultMaxAge
	) {
		self.directory = directory
		self.defaults = defaults
		self.now = now
		self.maxCount = maxCount
		self.maxAge = maxAge
		prepareDirectory()
		recordings = loadIndex()
		prune()
	}

	/// Creates the folder owner-only and tightens a folder and files left by older versions,
	/// which were created with the default umask.
	private func prepareDirectory() {
		let fileManager = FileManager.default
		do {
			try fileManager.createDirectory(
				at: directory, withIntermediateDirectories: true,
				attributes: [.posixPermissions: Self.directoryPermissions])
			try fileManager.setAttributes([.posixPermissions: Self.directoryPermissions], ofItemAtPath: directory.path)
			var url = directory
			var values = URLResourceValues()
			values.isExcludedFromBackup = true
			try url.setResourceValues(values)
		} catch {
			AppLogger.shared.audioManager.error("Could not prepare the cancelled recordings folder: \(error)")
		}
		let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
		for name in names {
			try? fileManager.setAttributes(
				[.posixPermissions: Self.filePermissions], ofItemAtPath: directory.appendingPathComponent(name).path)
		}
	}

	/// The "Keep cancelled recordings" setting. Off means a cancel discards its audio.
	var keepsRecordings: Bool {
		defaults.object(forKey: Self.keepRecordingsKey) as? Bool ?? Self.defaultKeepRecordings
	}

	/// Stores the setting; turning it off deletes every recording already kept.
	func setKeepsRecordings(_ keep: Bool) {
		defaults.set(keep, forKey: Self.keepRecordingsKey)
		applyKeepSetting()
	}

	/// Deletes everything when keeping is off, for a setting changed straight in UserDefaults
	/// (the Settings toggle writes through `@AppStorage`).
	func applyKeepSetting() {
		guard !keepsRecordings else { return }
		guard !recordings.isEmpty || hasStrayFiles else { return }
		deleteAll()
		AppLogger.shared.audioManager.info("Keeping cancelled recordings is off, deleted the kept ones")
	}

	private var hasStrayFiles: Bool {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return names.contains { $0.hasSuffix(".wav") && !pendingFileNames.contains($0) }
	}

	static func defaultDirectory() -> URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera", isDirectory: true)
			.appendingPathComponent("CancelledRecordings", isDirectory: true)
	}

	var latest: CancelledRecording? { recordings.first }

	func url(for recording: CancelledRecording) -> URL? {
		let url = directory.appendingPathComponent(recording.fileName)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	// MARK: - Saving

	/// Writes the samples off the main actor and adds the recording. Returns nil for a clip
	/// shorter than `minimumDuration` or when the file could not be written.
	@discardableResult
	func save(samples: [Float], sampleRate: Int = 16000) async -> CancelledRecording? {
		guard keepsRecordings else {
			AppLogger.shared.audioManager.info("Keeping cancelled recordings is off, discarding the audio")
			return nil
		}
		guard sampleRate > 0 else { return nil }
		let duration = Double(samples.count) / Double(sampleRate)
		guard duration >= Self.minimumDuration else {
			AppLogger.shared.audioManager.info("Cancelled recording too short to keep (\(duration) s)")
			return nil
		}
		let id = UUID()
		let name = "\(id.uuidString).wav"
		let destination = directory.appendingPathComponent(name)
		pendingFileNames.insert(name)
		defer { pendingFileNames.remove(name) }
		let permissions = Self.filePermissions
		let written = await Task.detached(priority: .utility) {
			Result {
				try WAVFileWriter.write(samples: samples, sampleRate: sampleRate, to: destination)
				try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
			}
		}.value
		if case .failure(let error) = written {
			AppLogger.shared.audioManager.error("Could not keep the cancelled recording: \(error)")
			removeFile(named: name)
			return nil
		}
		// The setting may have been turned off while the file was being written.
		guard keepsRecordings else {
			removeFile(named: name)
			return nil
		}
		return add(CancelledRecording(id: id, createdAt: now(), durationSeconds: duration, fileName: name))
	}

	/// Joins a record-to-file recording's parts into one 16 kHz file and removes the parts.
	@discardableResult
	func save(segments: [FileRecordingSegments.Segment]) async -> CancelledRecording? {
		guard !segments.isEmpty else { return nil }
		guard keepsRecordings else {
			FileRecordingSegments.removeFiles(of: segments)
			AppLogger.shared.audioManager.info("Keeping cancelled recordings is off, discarding the audio")
			return nil
		}
		let joined = await Task.detached(priority: .utility) {
			Result { try FileRecordingSegments.loadJoined(segments) }
		}.value
		FileRecordingSegments.removeFiles(of: segments)
		switch joined {
		case .success(let samples):
			return await save(samples: samples)
		case .failure(let error):
			AppLogger.shared.audioManager.error("Could not read the cancelled recording: \(error)")
			return nil
		}
	}

	private func add(_ recording: CancelledRecording) -> CancelledRecording? {
		recordings.insert(recording, at: 0)
		prune()
		AppLogger.shared.audioManager.info(
			"Kept cancelled recording \(recording.id) (\(String(format: "%.1f", recording.durationSeconds)) s)")
		return recordings.contains(recording) ? recording : nil
	}

	// MARK: - Removing

	func delete(_ recording: CancelledRecording) {
		if transcribingID == recording.id {
			cancelTranscription()
		}
		removeFile(named: recording.fileName)
		recordings.removeAll { $0.id == recording.id }
		saveIndex()
	}

	func deleteAll() {
		cancelTranscription()
		for recording in recordings {
			removeFile(named: recording.fileName)
		}
		recordings = []
		removeStrayFiles()
		saveIndex()
	}

	/// Drops recordings past the count or age limit, entries whose file is gone, and stray files
	/// no entry points at.
	func prune() {
		guard keepsRecordings else {
			applyKeepSetting()
			return
		}
		let cutoff = now().addingTimeInterval(-maxAge)
		let ordered = recordings.sorted { $0.createdAt > $1.createdAt }
		var kept: [CancelledRecording] = []
		for recording in ordered {
			let fileExists = FileManager.default.fileExists(
				atPath: directory.appendingPathComponent(recording.fileName).path)
			if recording.id != transcribingID,
				kept.count >= maxCount || recording.createdAt < cutoff || !fileExists
			{
				removeFile(named: recording.fileName)
			} else {
				kept.append(recording)
			}
		}
		recordings = kept
		removeStrayFiles()
		saveIndex()
	}

	private func removeStrayFiles() {
		let known = Set(recordings.map(\.fileName)).union(pendingFileNames)
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
		for name in names where name.hasSuffix(".wav") && !known.contains(name) {
			removeFile(named: name)
		}
	}

	private func removeFile(named name: String) {
		try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
	}

	// MARK: - Transcribing

	/// Runs `transcribe` on the recording's file. Only one runs at a time; `cancelTranscription`
	/// cancels it, and a cancelled run throws `CancellationError`.
	func transcribe(
		_ recording: CancelledRecording, using transcribe: @escaping @MainActor (URL) async throws -> String
	) async throws -> String {
		guard transcribingID == nil else { throw CancelledRecordingError.busy }
		guard let url = url(for: recording) else { throw CancelledRecordingError.audioUnavailable }
		let token = UUID()
		transcriptionToken = token
		transcribingID = recording.id
		let task = Task { @MainActor in try await transcribe(url) }
		transcriptionTask = task
		defer {
			if transcriptionToken == token {
				transcriptionToken = nil
				transcribingID = nil
				transcriptionTask = nil
			}
		}
		let text = try await task.value
		try Task.checkCancellation()
		if task.isCancelled { throw CancellationError() }
		return text
	}

	func cancelTranscription() {
		transcriptionTask?.cancel()
		transcriptionTask = nil
		transcriptionToken = nil
		transcribingID = nil
	}

	// MARK: - Index

	private func loadIndex() -> [CancelledRecording] {
		guard let data = defaults.data(forKey: Self.indexKey) else { return [] }
		do {
			return try JSONDecoder().decode([CancelledRecording].self, from: data)
		} catch {
			AppLogger.shared.audioManager.error("Unreadable cancelled recordings list, starting over: \(error)")
			return []
		}
	}

	private func saveIndex() {
		do {
			defaults.set(try JSONEncoder().encode(recordings), forKey: Self.indexKey)
		} catch {
			AppLogger.shared.audioManager.error("Could not save the cancelled recordings list: \(error)")
		}
	}
}

enum CancelledRecordingError: LocalizedError {
	case audioUnavailable
	case busy

	var errorDescription: String? {
		switch self {
		case .audioUnavailable: return String(localized: "This cancelled recording is no longer available.")
		case .busy: return String(localized: "A cancelled recording is already being transcribed.")
		}
	}
}
