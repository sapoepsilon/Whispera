import Foundation
import WhisperaLink

/// Relay messages already handled, by sender and envelope `message_id`, so one the relay
/// delivers again under a new sequence number is dropped. The relay keeps a message for up to
/// seven days and an envelope opens for its max age (`SealedEnvelope.defaultMaxAge`), so an
/// entry is kept until its envelope could no longer open (plus a day for clock drift). At most
/// `capacity` entries; past that the ones expiring first go (a tenth at a time). Only messages that opened (signed
/// by a listed device) are recorded, so nobody can flood the set without a device key.
///
/// Persisted to `relay_seen.json` in the helper's state directory (atomic, 0600) by `flush`,
/// which the mailbox's cursor save calls after every batch; `unpaired` flushes at once.
final class RelayReplayGuard: @unchecked Sendable {
	static let defaultCapacity = 10_000
	static let margin: Int64 = 24 * 3600
	static var retention: Int64 { SealedEnvelope.defaultMaxAge + SealedEnvelope.defaultFutureSkew + margin }

	private struct File: Codable {
		var v = 1
		/// `sender|message id hex` → when the entry may go (Unix seconds).
		var seen: [String: Int64] = [:]
	}

	let path: String
	let capacity: Int
	private let clock: @Sendable () -> Int64
	private let lock = NSLock()
	private var seen: [String: Int64] = [:]
	private var dirty = false

	init(
		path: String, capacity: Int = RelayReplayGuard.defaultCapacity,
		clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
	) {
		self.path = path
		self.capacity = max(1, capacity)
		self.clock = clock
		if let data = FileManager.default.contents(atPath: path), let file = try? JSONDecoder().decode(File.self, from: data) {
			seen = file.seen
		}
		lock.withLock { pruneLocked(now: clock()) }
	}

	/// True the first time `messageID` from `sender` is seen (and records it); false for a repeat.
	/// A message without an id (an old package build) is always new.
	func firstSeen(sender: String, messageID: Data, createdAt: Int64) -> Bool {
		guard !messageID.isEmpty else { return true }
		let key = sender + "|" + messageID.map { String(format: "%02x", $0) }.joined()
		let now = clock()
		return lock.withLock {
			if let until = seen[key], until > now { return false }
			seen[key] = max(createdAt, now) + Self.retention
			dirty = true
			if seen.count > capacity { pruneLocked(now: now) }
			return true
		}
	}

	var count: Int { lock.withLock { seen.count } }

	/// Writes the set when it changed since the last write.
	func flush() {
		let snapshot: [String: Int64]? = lock.withLock {
			guard dirty else { return nil }
			pruneLocked(now: clock())
			dirty = false
			return seen
		}
		guard let snapshot else { return }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		guard let data = try? encoder.encode(File(seen: snapshot)) else { return }
		do {
			try FileStore.writeAtomic(data, to: path)
		} catch {
			lock.withLock { dirty = true }
		}
	}

	/// Drops expired entries, then the soonest-expiring ones down to `capacity`.
	private func pruneLocked(now: Int64) {
		let before = seen.count
		seen = seen.filter { $0.value > now }
		if seen.count > capacity {
			let keep = capacity - capacity / 10
			let drop = seen.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(seen.count - keep)
			for (key, _) in drop { seen[key] = nil }
		}
		if seen.count != before { dirty = true }
	}
}
