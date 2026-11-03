import Foundation

/// The phone stopped waiting for a request: its connection closed, or it sent `api_cancel`.
/// Thrown by the blocking steps that check a `CancelToken`; LinkAPI answers nothing (no one is
/// listening) and logs `http.cancelled`.
struct RequestCancelled: Error {
	var reason: String
}

/// One request's cancel signal. The transport flips it (a direct connection closing, a relayed
/// `api_cancel`); the work checks it between steps and registers handlers that stop what it
/// started (a subprocess group, a URLSession task).
///
/// Each request runs on a thread of its own, so the token travels as that thread's
/// `CancelToken.current`: deep blocking calls (`HerdrCLI.spawn`, `SpeechService.runBlocking`,
/// the herdr socket) find it without every signature carrying it. Work that hops threads
/// captures it and re-installs it with `CancelToken.with`.
public final class CancelToken: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelledReason: String?
	private var handlers: [Int: () -> Void] = [:]
	private var nextHandler = 0

	public init() {}

	public var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelledReason != nil
	}

	public var reason: String? {
		lock.lock()
		defer { lock.unlock() }
		return cancelledReason
	}

	/// Flips the token once; the handlers registered so far run on the calling thread.
	public func cancel(_ reason: String) {
		lock.lock()
		guard cancelledReason == nil else {
			lock.unlock()
			return
		}
		cancelledReason = reason
		let pending = handlers.sorted { $0.key < $1.key }.map(\.value)
		handlers = [:]
		lock.unlock()
		for handler in pending { handler() }
	}

	/// Runs `handler` on cancel, or now when the token is already cancelled. The id removes it.
	@discardableResult
	func onCancel(_ handler: @escaping () -> Void) -> Int {
		lock.lock()
		if cancelledReason != nil {
			lock.unlock()
			handler()
			return -1
		}
		nextHandler += 1
		let id = nextHandler
		handlers[id] = handler
		lock.unlock()
		return id
	}

	func removeHandler(_ id: Int) {
		lock.lock()
		handlers[id] = nil
		lock.unlock()
	}

	func check() throws {
		if let reason { throw RequestCancelled(reason: reason) }
	}

	// MARK: The current thread's token

	private static let key = "whispera.link.cancel-token"
	private static let suspendedKey = "whispera.link.cancel-suspended"

	/// The token of the request this thread serves; nil outside a request and inside
	/// `withoutCancellation`.
	static var current: CancelToken? {
		let dictionary = Thread.current.threadDictionary
		if dictionary[suspendedKey] != nil { return nil }
		return dictionary[key] as? CancelToken
	}

	/// Runs `body` with `token` as this thread's current one.
	static func with<T>(_ token: CancelToken?, _ body: () throws -> T) rethrows -> T {
		let dictionary = Thread.current.threadDictionary
		let previous = dictionary[key]
		let suspended = dictionary[suspendedKey]
		dictionary[key] = token
		dictionary[suspendedKey] = nil
		defer {
			dictionary[key] = previous
			dictionary[suspendedKey] = suspended
		}
		return try body()
	}

	/// Runs `body` as if no one could cancel it: cleanup after a cancel (closing the tab a
	/// cancelled start opened) and writes that must not be torn halfway.
	static func withoutCancellation<T>(_ body: () throws -> T) rethrows -> T {
		let dictionary = Thread.current.threadDictionary
		let suspended = dictionary[suspendedKey]
		dictionary[suspendedKey] = true
		defer { dictionary[suspendedKey] = suspended }
		return try body()
	}

	/// Throws `RequestCancelled` when this thread's request was cancelled.
	static func checkCurrent() throws {
		try current?.check()
	}

	/// `Thread.sleep` that wakes early, and throws, when this thread's request is cancelled.
	static func sleep(_ seconds: TimeInterval) throws {
		guard let token = current else {
			Thread.sleep(forTimeInterval: seconds)
			return
		}
		let wake = DispatchSemaphore(value: 0)
		let id = token.onCancel { wake.signal() }
		_ = wake.wait(timeout: .now() + max(0, seconds))
		token.removeHandler(id)
		try token.check()
	}
}
