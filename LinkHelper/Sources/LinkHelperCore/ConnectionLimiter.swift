import Foundation

/// Caps the connections `HTTPServer` serves at once, per peer address and in total, so a peer
/// that opens connections faster than it closes them cannot make the helper spawn a thread for
/// each. A slot is taken at accept, before any thread exists, and given back when the
/// connection's handler returns or the connection fails before it is served.
public final class ConnectionLimiter: @unchecked Sendable {
	public static let defaultPerPeer = 16
	public static let defaultTotal = 128

	public let perPeer: Int
	public let total: Int
	private let lock = NSLock()
	private var byPeer: [String: Int] = [:]
	private var open = 0

	public init(perPeer: Int = defaultPerPeer, total: Int = defaultTotal) {
		self.perPeer = perPeer
		self.total = total
	}

	/// Takes a slot for `peer`; false when the peer or the server is at its cap.
	public func acquire(_ peer: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let current = byPeer[peer, default: 0]
		guard open < total, current < perPeer else { return false }
		byPeer[peer] = current + 1
		open += 1
		return true
	}

	/// Gives back a slot `acquire` took. A release without one is ignored.
	public func release(_ peer: String) {
		lock.lock()
		defer { lock.unlock() }
		guard let current = byPeer[peer] else { return }
		if current <= 1 { byPeer[peer] = nil } else { byPeer[peer] = current - 1 }
		open -= 1
	}

	public var openConnections: Int {
		lock.lock()
		defer { lock.unlock() }
		return open
	}

	public func openConnections(from peer: String) -> Int {
		lock.lock()
		defer { lock.unlock() }
		return byPeer[peer, default: 0]
	}

	/// One slot, released at most once however many paths try (a failed connection's state
	/// change and its handler's return can both get there).
	final class Slot: @unchecked Sendable {
		private let limiter: ConnectionLimiter
		let peer: String
		private let lock = NSLock()
		private var released = false

		init(_ limiter: ConnectionLimiter, peer: String) {
			self.limiter = limiter
			self.peer = peer
		}

		func release() {
			lock.lock()
			let first = !released
			released = true
			lock.unlock()
			if first { limiter.release(peer) }
		}
	}

	/// A slot for `peer`, or nil at the cap.
	func slot(for peer: String) -> Slot? {
		acquire(peer) ? Slot(self, peer: peer) : nil
	}
}
