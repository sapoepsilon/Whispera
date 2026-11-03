import Foundation

#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

/// One frame from the server.
public enum DictationTransportFrame: Sendable, Equatable {
	case text(String)
	/// The peer closed. `code` is the WebSocket close code, or the HTTP status when
	/// the upgrade itself was refused.
	case closed(code: Int, reason: String)
}

/// The socket, behind a seam.
///
/// The interesting behaviour in this package is not "can it open a WebSocket" —
/// it is what happens on a `4401`, whether the credential provider is consulted
/// again, and whether it gives up after exactly one retry. Driving that through a
/// real socket would mean a server that can be told to reject the first token, on
/// a machine with no Xcode. Behind this protocol a test states it in ten lines.
public protocol DictationTransport: Sendable {
	/// Opens the socket. Throws if the upgrade fails; an HTTP 401 must surface as
	/// `DictationError.unauthorized`, which is what drives the retry.
	func connect(to request: URLRequest) async throws
	func send(_ text: String) async throws
	/// The next frame, or `nil` once the stream is done.
	func receive() async throws -> DictationTransportFrame?
	func close() async
}

/// How a session gets its transport. A factory rather than an instance because a
/// retry needs a *second* socket — a closed `URLSessionWebSocketTask` cannot be
/// reopened.
public struct DictationTransportFactory: Sendable {
	private let make: @Sendable () -> DictationTransport

	public init(_ make: @escaping @Sendable () -> DictationTransport) { self.make = make }

	public func callAsFunction() -> DictationTransport { make() }

	public static var urlSession: DictationTransportFactory {
		DictationTransportFactory { URLSessionDictationTransport() }
	}
}

/// The shipping transport.
public final class URLSessionDictationTransport: NSObject, DictationTransport, @unchecked Sendable {
	private let lock = NSLock()
	private var task: URLSessionWebSocketTask?
	private var session: URLSession?
	/// Set from the delegate when the peer closes, so that a `receive()` failing
	/// with a generic socket error can still report the real close code.
	private var observedClose: (code: Int, reason: String)?

	public override init() { super.init() }

	public func connect(to request: URLRequest) async throws {
		let configuration = URLSessionConfiguration.ephemeral
		// The engine can sit silent between utterances; the default 60s request
		// timeout would tear a live dictation down mid-thought.
		configuration.timeoutIntervalForRequest = 300
		configuration.timeoutIntervalForResource = 3600

		let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		let task = session.webSocketTask(with: request)

		lock.withLock {
			self.session = session
			self.task = task
			self.observedClose = nil
		}

		task.resume()

		// Deliberately does not wait for the handshake.
		//
		// The obvious probe is `sendPing`, and it does not work here: its completion
		// fires only when a pong comes back, and the uvicorn-hosted engine this was
		// developed against never sends one, so `connect` hung indefinitely against
		// a server that was in fact working. A refused upgrade instead surfaces on
		// the first `receive()`, where `classify` reads the HTTP status off the task
		// and turns a 401 into `.unauthorized`. The session bounds the wait with its
		// own handshake timeout, because the engine speaks first.
	}

	public func send(_ text: String) async throws {
		let task = lock.withLock { self.task }
		guard let task else { throw DictationError.connectionFailed("the socket is not open") }
		do {
			try await task.send(.string(text))
		} catch {
			throw classify(error)
		}
	}

	public func receive() async throws -> DictationTransportFrame? {
		let task = lock.withLock { self.task }
		guard let task else { return nil }

		let message: URLSessionWebSocketTask.Message
		do {
			message = try await task.receive()
		} catch {
			// A close is a normal end of stream, not a failure — but only after the
			// close code has been read, because that code is how `4401` is detected.
			if let close = closeInfo(from: task) {
				return .closed(code: close.code, reason: close.reason)
			}
			throw classify(error)
		}

		switch message {
		case .string(let text):
			return .text(text)
		case .data:
			// Both directions are text JSON. A binary frame means something upstream
			// is misconfigured, and silently ignoring it would leave a host waiting
			// on a transcript forever.
			throw DictationError.protocolViolation("server sent a binary frame; this protocol is text-only")
		@unknown default:
			throw DictationError.protocolViolation("server sent an unrecognised frame kind")
		}
	}

	private func closeInfo(from task: URLSessionWebSocketTask) -> (code: Int, reason: String)? {
		if let observed = lock.withLock({ observedClose }) { return observed }

		let code = task.closeCode
		guard code != .invalid else { return nil }
		let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
		return (Int(code.rawValue), reason)
	}

	/// Maps a URLSession error onto this package's vocabulary.
	private func classify(_ error: Error) -> DictationError {
		let response = lock.withLock { task?.response as? HTTPURLResponse }

		// The refused upgrade. The backend's auth runs as a preHandler on the
		// upgrade request, so an unauthenticated client gets an HTTP 401 and no
		// WebSocket at all — there is no 4401 close frame to read in that case.
		if let status = response?.statusCode {
			if status == 401 || status == 403 { return .unauthorized }
			if status >= 400 {
				return .connectionFailed("the server refused the upgrade with HTTP \(status)")
			}
		}
		if let alreadyClassified = error as? DictationError { return alreadyClassified }
		return .connectionFailed(error.localizedDescription)
	}

	public func close() async {
		let (task, session) = lock.withLock {
			let pair = (self.task, self.session)
			self.task = nil
			self.session = nil
			return pair
		}

		task?.cancel(with: .goingAway, reason: nil)
		// Without this the ephemeral session keeps its delegate — and therefore
		// this object — alive after the socket is gone.
		session?.invalidateAndCancel()
	}
}

extension URLSessionDictationTransport: URLSessionWebSocketDelegate {
	public func urlSession(
		_ session: URLSession,
		webSocketTask: URLSessionWebSocketTask,
		didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
		reason: Data?
	) {
		lock.withLock {
			observedClose = (Int(closeCode.rawValue), reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
		}
	}
}
