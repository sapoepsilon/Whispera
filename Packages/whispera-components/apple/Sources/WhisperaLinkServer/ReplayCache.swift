import Foundation

/// Remembers `(device_id, nonce)` pairs for PROTOCOL §4.3 step 6.
///
/// Entries live `ttl` seconds (default `2 × clock_skew_s` = 120 s): anything older is
/// already refused by the clock-skew check, so forgetting it opens nothing. At most
/// `capacity` entries (default 10 000); on overflow the oldest go first. In memory on
/// purpose — a restart clears it, and the skew window bounds that exposure.
///
/// Thread-safe; one instance is shared by every request handler.
public final class ReplayCache: @unchecked Sendable {
	public let ttl: Int64
	public let capacity: Int

	private struct Key: Hashable {
		var deviceID: String
		var nonce: String
	}

	private let lock = NSLock()
	private var expiry: [Key: Int64] = [:]
	/// Insertion order. Entries are added with non-decreasing `now` in practice, so the
	/// front is also the oldest; `head` avoids O(n) removals from the front.
	private var order: [(key: Key, expires: Int64)] = []
	private var head = 0

	public init(ttl: Int64 = 2 * Int64(60), capacity: Int = 10_000) {
		precondition(capacity > 0)
		self.ttl = ttl
		self.capacity = capacity
	}

	/// Records the pair and returns `true` if it was new; `false` means a replay.
	@discardableResult
	public func insert(deviceID: String, nonce: String, now: Int64) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		purge(now: now)
		let key = Key(deviceID: deviceID, nonce: nonce)
		if let expires = expiry[key], expires > now { return false }
		let expires = now + ttl
		expiry[key] = expires
		order.append((key, expires))
		while expiry.count > capacity { evictOldest() }
		compactIfNeeded()
		return true
	}

	public func contains(deviceID: String, nonce: String, now: Int64) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard let expires = expiry[Key(deviceID: deviceID, nonce: nonce)] else { return false }
		return expires > now
	}

	public var count: Int {
		lock.lock()
		defer { lock.unlock() }
		return expiry.count
	}

	private func purge(now: Int64) {
		while head < order.count, order[head].expires <= now {
			let entry = order[head]
			if expiry[entry.key] == entry.expires { expiry[entry.key] = nil }
			head += 1
		}
	}

	private func evictOldest() {
		while head < order.count {
			let entry = order[head]
			head += 1
			if expiry[entry.key] == entry.expires {
				expiry[entry.key] = nil
				return
			}
		}
	}

	private func compactIfNeeded() {
		if head > 1024, head * 2 > order.count {
			order.removeFirst(head)
			head = 0
		}
	}
}
