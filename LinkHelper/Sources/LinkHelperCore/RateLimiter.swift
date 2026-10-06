import Foundation

/// More than `limit` failed authentications from one address within `window` seconds blocks
/// that address for `blockFor` seconds (PROTOCOL §4.3).
final class RateLimiter: @unchecked Sendable {
	let limit: Int
	let window: Double
	let blockFor: Double
	private let clock: @Sendable () -> Double
	private let lock = NSLock()
	private var failures: [String: [Double]] = [:]
	private var blocked: [String: Double] = [:]

	init(
		limit: Int = 20, window: Double = 60, blockFor: Double = 60,
		clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
	) {
		self.limit = limit
		self.window = window
		self.blockFor = blockFor
		self.clock = clock
	}

	func isBlocked(_ address: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard let until = blocked[address] else { return false }
		if clock() >= until {
			blocked[address] = nil
			return false
		}
		return true
	}

	func fail(_ address: String) {
		lock.lock()
		defer { lock.unlock() }
		let now = clock()
		var recent = (failures[address] ?? []).filter { now - $0 <= window }
		recent.append(now)
		if recent.count > limit {
			blocked[address] = now + blockFor
			recent.removeAll()
		}
		failures[address] = recent
		if failures.count > 4096 { failures = failures.filter { !$0.value.isEmpty } }
	}
}

/// `~/.whispera-link/last_device`: the device that signed the latest request, which the broker
/// forwards as `prefer_device` so the next approval pushes to that phone first (§8).
final class LastDeviceFile: @unchecked Sendable {
	let path: String
	private let lock = NSLock()
	private var written: String?

	init(path: String) {
		self.path = path
		written = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(
			in: .whitespacesAndNewlines)
	}

	/// The device recorded last, if any.
	var current: String? {
		lock.lock()
		defer { lock.unlock() }
		return written.flatMap { $0.isEmpty ? nil : $0 }
	}

	func record(_ deviceID: String) {
		lock.lock()
		defer { lock.unlock() }
		guard written != deviceID || !FileManager.default.fileExists(atPath: path) else { return }
		if (try? FileStore.writeAtomic(Data((deviceID + "\n").utf8), to: path)) != nil { written = deviceID }
	}
}
