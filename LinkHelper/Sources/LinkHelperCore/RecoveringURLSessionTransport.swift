import Foundation
import WhisperaLink

/// The account backend's transport: `URLSessionLinkTransport`'s session, replaced by a fresh one
/// once a request through it times out or loses its connection.
///
/// URLSession multiplexes every call to the backend over one pooled HTTP/2 connection. When the
/// path under that connection dies without a reset (a VPN tunnel that re-keys or drops, a NAT
/// that forgets the flow, a Wi-Fi handover), every later request is queued on the dead
/// connection and times out too, until TCP gives up on it minutes later. A new session has an
/// empty pool, so the next request opens a new connection. The old session finishes its
/// in-flight tasks and is then invalidated.
public final class RecoveringURLSessionTransport: LinkTransport, @unchecked Sendable {
	/// The failures that point at the pooled connection rather than at the request.
	static let staleConnectionCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost]

	private let lock = NSLock()
	private let makeSession: @Sendable () -> URLSession
	private let onRecycle: @Sendable (URLError.Code) -> Void
	private var current: URLSession
	private var recycled = 0

	public init(
		makeSession: @escaping @Sendable () -> URLSession = { URLSessionLinkTransport.makeSession() },
		onRecycle: @escaping @Sendable (URLError.Code) -> Void = { _ in }
	) {
		self.makeSession = makeSession
		self.onRecycle = onRecycle
		current = makeSession()
	}

	deinit {
		current.finishTasksAndInvalidate()
	}

	public var session: URLSession {
		lock.lock()
		defer { lock.unlock() }
		return current
	}

	/// How many times the session was replaced.
	public var recycleCount: Int {
		lock.lock()
		defer { lock.unlock() }
		return recycled
	}

	public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let session = self.session
		do {
			let (data, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
			return (data, http)
		} catch {
			recycleIfStale(session, after: error)
			throw error
		}
	}

	public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse) {
		let session = self.session
		let bytes: URLSession.AsyncBytes
		let response: URLResponse
		do {
			(bytes, response) = try await session.bytes(for: request)
		} catch {
			recycleIfStale(session, after: error)
			throw error
		}
		guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
		let stream = AsyncThrowingStream<UInt8, Error> { continuation in
			let task = Task { [weak self] in
				do {
					for try await byte in bytes { continuation.yield(byte) }
					continuation.finish()
				} catch {
					self?.recycleIfStale(session, after: error)
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
		return (stream, http)
	}

	/// Replaces `stale` when `error` blames its connection and it is still the current session,
	/// so concurrent failures on one dead connection replace it once.
	func recycleIfStale(_ stale: URLSession, after error: Error) {
		guard let code = Self.urlErrorCode(error), Self.staleConnectionCodes.contains(code) else { return }
		lock.lock()
		guard current === stale else {
			lock.unlock()
			return
		}
		current = makeSession()
		recycled += 1
		lock.unlock()
		stale.finishTasksAndInvalidate()
		onRecycle(code)
	}

	private static func urlErrorCode(_ error: Error) -> URLError.Code? {
		if let error = error as? URLError { return error.code }
		let error = error as NSError
		return error.domain == NSURLErrorDomain ? URLError.Code(rawValue: error.code) : nil
	}
}
