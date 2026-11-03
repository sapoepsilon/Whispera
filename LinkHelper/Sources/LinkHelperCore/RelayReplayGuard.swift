import Foundation
import WhisperaLink

/// Relay messages already handled, by sender and envelope `message_id`, so one the relay
/// delivers again under a new sequence number is dropped. The relay keeps a message for up to
/// seven days and an envelope opens for its max age (`SealedEnvelope.defaultMaxAge`), so an
/// entry is kept until its envelope could no longer open (plus a day for clock drift). Only
/// messages that opened (signed by a listed device) are recorded.
///
/// Every sender has its own budget, so one sender's traffic never evicts another's entries:
/// a sender the owner confirmed here (`trusted`) keeps up to `capacity` entries, any other
/// listed device up to `untrustedPerSender`, and all of those together up to `untrustedTotal`
/// (the backend can list as many fake devices as it likes; they share that pool, never the
/// confirmed phones' budget). When entries of a sender go to make room, the sender's low-water
/// mark rises to the newest `created_at` evicted, and any envelope from that sender created at
/// or before the mark is refused: forgetting an id never lets its envelope in again.
///
/// Persisted to `relay_seen.json` in the helper's state directory (atomic, 0600) by `flush`,
/// which the mailbox's cursor save calls after every batch; `unpaired` flushes at once.
final class RelayReplayGuard: @unchecked Sendable {
	static let defaultCapacity = 4096
	static let untrustedPerSender = 64
	static let untrustedTotal = 2048
	static let margin: Int64 = 24 * 3600
	static var retention: Int64 { SealedEnvelope.defaultMaxAge + SealedEnvelope.defaultFutureSkew + margin }

	private struct File: Codable {
		var v = 2
		/// sender → message id hex → the envelope's `created_at`.
		var trusted: [String: [String: Int64]] = [:]
		var untrusted: [String: [String: Int64]] = [:]
		/// sender → newest `created_at` evicted for it.
		var floors: [String: Int64] = [:]
	}

	/// Version 1: `sender|message id hex` → when the entry may go.
	private struct LegacyFile: Codable {
		var seen: [String: Int64]
	}

	let path: String
	let capacity: Int
	private let clock: @Sendable () -> Int64
	private let lock = NSLock()
	private var trusted: [String: [String: Int64]] = [:]
	private var untrusted: [String: [String: Int64]] = [:]
	private var floors: [String: Int64] = [:]
	private var dirty = false

	init(
		path: String, capacity: Int = RelayReplayGuard.defaultCapacity,
		clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
	) {
		self.path = path
		self.capacity = max(10, capacity)
		self.clock = clock
		if let data = FileManager.default.contents(atPath: path) {
			if let file = try? JSONDecoder().decode(File.self, from: data), file.v == 2 {
				trusted = file.trusted
				untrusted = file.untrusted
				floors = file.floors
			} else if let legacy = try? JSONDecoder().decode(LegacyFile.self, from: data) {
				for (key, until) in legacy.seen {
					let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
					guard parts.count == 2 else { continue }
					trusted[parts[0], default: [:]][parts[1]] = until - Self.retention
				}
				dirty = true
			}
		}
		lock.withLock { pruneLocked(now: clock()) }
	}

	/// True the first time `messageID` from `sender` is seen (and records it); false for a repeat
	/// or for an envelope at or below the sender's low-water mark. `trusted`: the sender is a
	/// device the owner confirmed here. A message without an id (an old package build) is always new.
	func firstSeen(sender: String, messageID: Data, createdAt: Int64, trusted isTrusted: Bool = true) -> Bool {
		guard !messageID.isEmpty else { return true }
		let id = messageID.map { String(format: "%02x", $0) }.joined()
		let now = clock()
		return lock.withLock {
			if let floor = floors[sender], createdAt <= floor { return false }
			if let at = trusted[sender]?[id] ?? untrusted[sender]?[id], at + Self.retention > now { return false }
			if isTrusted, let moved = untrusted.removeValue(forKey: sender) {
				trusted[sender, default: [:]].merge(moved) { max($0, $1) }
			}
			dirty = true
			if isTrusted || trusted[sender] != nil {
				trusted[sender, default: [:]][id] = createdAt
				evictLocked(sender, in: &trusted, to: capacity)
			} else {
				untrusted[sender, default: [:]][id] = createdAt
				evictLocked(sender, in: &untrusted, to: Self.untrustedPerSender)
				evictUntrustedPoolLocked()
			}
			return true
		}
	}

	var count: Int { lock.withLock { (trusted.values.map(\.count) + untrusted.values.map(\.count)).reduce(0, +) } }

	func entries(of sender: String) -> Int {
		lock.withLock { (trusted[sender]?.count ?? 0) + (untrusted[sender]?.count ?? 0) }
	}

	func lowWaterMark(of sender: String) -> Int64? { lock.withLock { floors[sender] } }

	/// Writes the set when it changed since the last write.
	func flush() {
		let snapshot: File? = lock.withLock {
			pruneLocked(now: clock())
			guard dirty else { return nil }
			dirty = false
			return File(trusted: trusted, untrusted: untrusted, floors: floors)
		}
		guard let snapshot else { return }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		guard let data = try? encoder.encode(snapshot) else { return }
		do {
			try FileStore.writeAtomic(data, to: path)
		} catch {
			lock.withLock { dirty = true }
		}
	}

	/// Drops the oldest entries of `sender` down to nine tenths of `limit` once it is over, and
	/// raises its low-water mark to the newest one dropped.
	private func evictLocked(_ sender: String, in map: inout [String: [String: Int64]], to limit: Int) {
		guard let bucket = map[sender], bucket.count > limit else { return }
		let keep = limit - limit / 10
		let drop = bucket.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(bucket.count - keep)
		var remaining = bucket
		for (id, at) in drop {
			remaining[id] = nil
			floors[sender] = max(floors[sender] ?? .min, at)
		}
		map[sender] = remaining
	}

	/// Keeps every unconfirmed sender together under `untrustedTotal`: the oldest entries go
	/// first, whoever sent them, each raising its own sender's mark. Low-water marks of senders
	/// with no entries left are bounded the same way (the oldest go).
	private func evictUntrustedPoolLocked() {
		var total = untrusted.values.map(\.count).reduce(0, +)
		guard total > Self.untrustedTotal else { return }
		let keep = Self.untrustedTotal - Self.untrustedTotal / 10
		let all = untrusted.flatMap { sender, bucket in bucket.map { (sender, $0.key, $0.value) } }
			.sorted { ($0.2, $0.0, $0.1) < ($1.2, $1.0, $1.1) }
		for (sender, id, at) in all where total > keep {
			untrusted[sender]?[id] = nil
			floors[sender] = max(floors[sender] ?? .min, at)
			total -= 1
		}
		untrusted = untrusted.filter { !$0.value.isEmpty }
		let orphanFloors = floors.filter { trusted[$0.key] == nil && untrusted[$0.key] == nil }
		if orphanFloors.count > Self.untrustedTotal {
			for (sender, _) in orphanFloors.sorted(by: { $0.value < $1.value }).prefix(orphanFloors.count - keep) {
				floors[sender] = nil
			}
		}
	}

	/// Drops entries and marks whose envelopes could no longer open.
	private func pruneLocked(now: Int64) {
		func prune(_ map: inout [String: [String: Int64]]) {
			for (sender, bucket) in map {
				let live = bucket.filter { $0.value + Self.retention > now }
				if live.count != bucket.count {
					map[sender] = live.isEmpty ? nil : live
					dirty = true
				}
			}
		}
		prune(&trusted)
		prune(&untrusted)
		let liveFloors = floors.filter { $0.value + Self.retention > now }
		if liveFloors.count != floors.count {
			floors = liveFloors
			dirty = true
		}
	}
}
