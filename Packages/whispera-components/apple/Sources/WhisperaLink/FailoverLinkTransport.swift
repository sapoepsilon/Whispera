import Foundation

/// Direct first, relay when the Mac cannot be reached.
///
/// * On `.direct`, a connect-level error (`isConnectError`: cannot connect, timed
///   out, host not found, network lost) switches to `.relay`. The failed request is
///   retried there with the same signed bytes (the host is not signed) only when it
///   never left the phone (`isUndelivered`: cannot connect, host not found). After a
///   timeout or a dropped connection the Mac may already have it and has spent its
///   nonce, so the same bytes over the relay would come back `401 auth_replay`; the
///   error is thrown instead and the caller re-signs (`LinkClient` does for GET).
///   A failed `probeDirect()` (`GET /v1/health` within `probeTimeout`) switches too.
/// * On `.relay`, direct is re-probed every `reprobeInterval`; a healthy probe
///   switches back to `.direct`.
/// * An HTTP error status is an answer from the Mac, never a reason to fail over.
///
/// `path` and `pathChanges()` drive the "Direct" / "Via relay" label. `forceRelay`
/// (a test hook, `-WLForceRelay YES`) pins everything to the relay.
public final class FailoverLinkTransport: LinkTransport, @unchecked Sendable {
	public enum Path: String, Sendable, Equatable {
		case direct, relay
	}

	public let direct: LinkTransport
	public let relay: LinkTransport
	public let reprobeInterval: TimeInterval
	public let probeTimeout: TimeInterval

	public static let defaultReprobeInterval: TimeInterval = 30
	public static let defaultProbeTimeout: TimeInterval = 3

	private let lock = NSLock()
	private var currentPath: Path = .direct
	private var forced: Bool
	private var probeBase: URL?
	private var reprobeTask: Task<Void, Never>?
	private var observers: [UUID: AsyncStream<Path>.Continuation] = [:]

	/// - Parameter directBaseURL: the Mac's direct LinkAPI base, for health probes.
	///   When nil it is taken from the first request (`scheme://host:port`).
	public init(
		direct: LinkTransport, relay: LinkTransport, directBaseURL: URL? = nil,
		reprobeInterval: TimeInterval = FailoverLinkTransport.defaultReprobeInterval,
		probeTimeout: TimeInterval = FailoverLinkTransport.defaultProbeTimeout, forceRelay: Bool = false
	) {
		self.direct = direct
		self.relay = relay
		probeBase = directBaseURL
		self.reprobeInterval = reprobeInterval
		self.probeTimeout = probeTimeout
		forced = forceRelay
		if forceRelay { currentPath = .relay }
	}

	deinit {
		reprobeTask?.cancel()
		for continuation in observers.values { continuation.finish() }
	}

	/// The path the next request takes.
	public var path: Path { lock.withLock { currentPath } }

	/// Pins every request to the relay while true. Turning it off goes back to
	/// direct-first.
	public var forceRelay: Bool {
		get { lock.withLock { forced } }
		set {
			lock.withLock { forced = newValue }
			setPath(newValue ? .relay : .direct, reprobe: false)
		}
	}

	/// The current path, then every change.
	public func pathChanges() -> AsyncStream<Path> {
		let (stream, continuation) = AsyncStream<Path>.makeStream(bufferingPolicy: .bufferingNewest(8))
		let id = UUID()
		let current: Path = lock.withLock {
			observers[id] = continuation
			return currentPath
		}
		continuation.yield(current)
		continuation.onTermination = { [weak self] _ in
			self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) }
		}
		return stream
	}

	// MARK: LinkTransport

	public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		guard route(request) == .direct else { return try await relay.data(for: request) }
		do {
			return try await direct.data(for: request)
		} catch where Self.isConnectError(error) {
			guard !Task.isCancelled else { throw error }
			setPath(.relay, reprobe: true)
			guard Self.isUndelivered(error) else { throw error }
			return try await relay.data(for: request)
		}
	}

	public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse) {
		guard route(request) == .direct else { return try await relay.stream(for: request) }
		do {
			return try await direct.stream(for: request)
		} catch where Self.isConnectError(error) {
			guard !Task.isCancelled else { throw error }
			setPath(.relay, reprobe: true)
			guard Self.isUndelivered(error) else { throw error }
			return try await relay.stream(for: request)
		}
	}

	// MARK: Probing

	/// `GET /v1/health` straight to the Mac within `probeTimeout`. Switches to
	/// `.direct` on a 200 and to `.relay` otherwise (unless forced). Returns whether
	/// direct is reachable.
	@discardableResult
	public func probeDirect() async -> Bool {
		let healthy = await isDirectHealthy()
		if !lock.withLock({ forced }) { setPath(healthy ? .direct : .relay, reprobe: !healthy) }
		return healthy
	}

	/// Whether `error` means "could not reach the Mac at all" — the only kind that
	/// fails over.
	public static func isConnectError(_ error: Error) -> Bool {
		guard let code = urlErrorCode(error) else { return false }
		return [.cannotConnectToHost, .timedOut, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost].contains(code)
	}

	/// Whether a connect-level `error` proves the request never reached the Mac, so
	/// resending the same signed bytes cannot be a replay.
	public static func isUndelivered(_ error: Error) -> Bool {
		guard isConnectError(error), let code = urlErrorCode(error) else { return false }
		return [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code)
	}

	private static func urlErrorCode(_ error: Error) -> URLError.Code? {
		if let error = error as? URLError { return error.code }
		if (error as NSError).domain == NSURLErrorDomain { return URLError.Code(rawValue: (error as NSError).code) }
		return nil
	}

	private func route(_ request: URLRequest) -> Path {
		lock.withLock {
			if probeBase == nil, let url = request.url, url.scheme != RelayAPI.placeholderScheme {
				probeBase = Self.base(of: url)
			}
			return forced ? .relay : currentPath
		}
	}

	private func isDirectHealthy() async -> Bool {
		guard let base = lock.withLock({ probeBase }) else { return false }
		var string = base.absoluteString
		while string.hasSuffix("/") { string.removeLast() }
		guard let url = URL(string: string + "/v1/health") else { return false }
		var request = URLRequest(url: url)
		request.timeoutInterval = probeTimeout
		request.cachePolicy = .reloadIgnoringLocalCacheData
		let direct = direct
		let timeout = probeTimeout
		return await withTaskGroup(of: Bool.self) { group in
			group.addTask {
				guard let (_, response) = try? await direct.data(for: request) else { return false }
				return response.statusCode == 200
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
				return false
			}
			let first = await group.next() ?? false
			group.cancelAll()
			return first
		}
	}

	private func setPath(_ new: Path, reprobe: Bool) {
		let (changed, watchers): (Bool, [AsyncStream<Path>.Continuation]) = lock.withLock {
			let changed = currentPath != new
			currentPath = new
			if new == .direct {
				reprobeTask?.cancel()
				reprobeTask = nil
			}
			return (changed, Array(observers.values))
		}
		if changed { for watcher in watchers { watcher.yield(new) } }
		if new == .relay, reprobe { startReprobing() }
	}

	private func startReprobing() {
		lock.lock()
		defer { lock.unlock() }
		guard reprobeTask == nil else { return }
		let interval = reprobeInterval
		reprobeTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
				guard !Task.isCancelled, let self else { return }
				if self.lock.withLock({ self.forced }) { continue }
				if await self.isDirectHealthy() {
					self.lock.withLock { self.reprobeTask = nil }
					self.setPath(.direct, reprobe: false)
					return
				}
			}
		}
	}

	static func base(of url: URL) -> URL? {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
		components.path = ""
		components.query = nil
		components.fragment = nil
		return components.url
	}
}
