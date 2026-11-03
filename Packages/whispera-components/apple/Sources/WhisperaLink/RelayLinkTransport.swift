import Foundation

/// The phone's `LinkTransport` over the E2E relay: the already WL1-signed request is
/// serialised as an `api_request` (`target` = path + query exactly as signed, the
/// host dropped), sealed to the Mac's account device and sent with `ttl_s` 120; the
/// answer comes back as `api_response` frames through the shared `RelayMailbox`,
/// accepted only from that Mac's device id.
///
/// `LinkClient` is unchanged on top of it: build it on the Mac's direct base URL (for
/// `FailoverLinkTransport`) or on `RelayAPI.placeholderBaseURL(macDeviceID:)` — the
/// host is not signed, so either works.
public final class RelayLinkTransport: LinkTransport, @unchecked Sendable {
	public let mailbox: RelayMailbox
	public let macDeviceID: String
	public let ttl: UInt32
	/// A relayed stream with no frame for this long fails with `URLError(.timedOut)`.
	public let streamIdleTimeout: TimeInterval
	/// Used when a request's `timeoutInterval` is not positive.
	public static let fallbackTimeout: TimeInterval = 60
	/// The longest a whole (non-stream) relayed response may take while its frames keep coming.
	public static let maxDuration: TimeInterval = 300

	private let resolveMac: @Sendable () async throws -> TrustedDevice

	/// Resolves the Mac in the mailbox's current devices on every call, so a
	/// refreshed device list is picked up; refreshes once when the Mac is missing.
	public init(
		mailbox: RelayMailbox, macDeviceID: String, ttl: UInt32 = RelayAPI.ttl,
		streamIdleTimeout: TimeInterval = RelayAPI.streamIdleTimeout
	) {
		self.mailbox = mailbox
		self.macDeviceID = macDeviceID
		self.ttl = ttl
		self.streamIdleTimeout = streamIdleTimeout
		resolveMac = { [mailbox] in
			if let mac = try await mailbox.devices(refresh: false).peer(macDeviceID) { return mac }
			if let mac = try await mailbox.devices(refresh: true).peer(macDeviceID) { return mac }
			throw RelayError.unknownSender(macDeviceID)
		}
	}

	/// A fixed, already verified Mac.
	public init(
		mailbox: RelayMailbox, mac: TrustedDevice, ttl: UInt32 = RelayAPI.ttl,
		streamIdleTimeout: TimeInterval = RelayAPI.streamIdleTimeout
	) {
		self.mailbox = mailbox
		macDeviceID = mac.id
		self.ttl = ttl
		self.streamIdleTimeout = streamIdleTimeout
		resolveMac = { mac }
	}

	// MARK: LinkTransport

	public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let call = try RelayAPIRequest(request, stream: false)
		let mac = try await resolveMac()
		let frames = await mailbox.responses(id: call.id, from: mac.id)
		do {
			try await mailbox.client.send(.apiRequest(call), to: mac, ttl: ttl)
		} catch {
			await mailbox.removeWaiter(id: call.id)
			throw error
		}
		let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : Self.fallbackTimeout
		// The timeout is for silence, not the whole answer: a large response arrives as many
		// frames, each a relay round trip, and may take longer than the request's timeout
		// while it keeps coming. `maxDuration` still bounds it.
		let watchdog = SSEWatchdog(timeout: timeout)
		let limit = max(timeout, Self.maxDuration)
		do {
			let (status, headers, body) = try await withThrowingTaskGroup(
				of: (Int, [String: String], Data).self
			) { group in
				group.addTask {
					var assembler = RelayAPIResponseAssembler(id: call.id)
					for try await frame in frames {
						await watchdog.touch()
						_ = try assembler.accept(frame)
						if assembler.isComplete, let status = assembler.status {
							return (status, assembler.headers, assembler.body)
						}
					}
					try Task.checkCancellation()
					throw RelayAPIError.incomplete
				}
				group.addTask {
					try await watchdog.waitForStall()
					throw URLError(.timedOut)
				}
				group.addTask {
					try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
					throw URLError(.timedOut)
				}
				defer { group.cancelAll() }
				return try await group.next()!
			}
			await mailbox.removeWaiter(id: call.id)
			return (body, Self.response(for: request, status: status, headers: headers))
		} catch {
			await mailbox.removeWaiter(id: call.id)
			sendCancel(call.id, to: mac)
			throw error
		}
	}

	public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse) {
		let call = try RelayAPIRequest(request, stream: true)
		let mac = try await resolveMac()
		let frames = await mailbox.responses(id: call.id, from: mac.id)
		do {
			try await mailbox.client.send(.apiRequest(call), to: mac, ttl: ttl)
		} catch {
			await mailbox.removeWaiter(id: call.id)
			throw error
		}

		let idle = min(streamIdleTimeout, request.timeoutInterval > 0 ? request.timeoutInterval : streamIdleTimeout)
		let head = StreamHead()
		let (bytes, output) = AsyncThrowingStream<UInt8, Error>.makeStream()
		let client = mailbox.client, ttl = ttl
		output.onTermination = { _ in
			head.cancelFeeder()
			if !head.isComplete { Self.sendCancel(call.id, to: mac, client: client, ttl: ttl) }
		}
		head.setFeeder(Task { [mailbox] in
			do {
				let watchdog = SSEWatchdog(timeout: idle)
				try await withThrowingTaskGroup(of: Void.self) { group in
					group.addTask {
						var assembler = RelayAPIResponseAssembler(id: call.id, collectsBody: false)
						var announced = false
						for try await frame in frames {
							await watchdog.touch()
							let chunks = try assembler.accept(frame)
							if !announced, let status = assembler.status {
								announced = true
								head.resolve(status: status, headers: assembler.headers)
							}
							for chunk in chunks { for byte in chunk { output.yield(byte) } }
							if assembler.isComplete {
								head.markComplete()
								return
							}
						}
						try Task.checkCancellation()
						throw RelayAPIError.incomplete
					}
					group.addTask {
						try await watchdog.waitForStall()
						throw URLError(.timedOut)
					}
					defer { group.cancelAll() }
					try await group.next()
				}
				output.finish()
			} catch {
				head.fail(error)
				output.finish(throwing: error)
			}
			await mailbox.removeWaiter(id: call.id)
		})

		do {
			let (status, headers) = try await head.wait()
			return (bytes, Self.response(for: request, status: status, headers: headers))
		} catch {
			head.cancelFeeder()
			output.finish(throwing: error)
			throw error
		}
	}

	// MARK: Helpers

	/// Best effort: tells the Mac to stop working on `id`.
	func sendCancel(_ id: String, to mac: TrustedDevice) {
		Self.sendCancel(id, to: mac, client: mailbox.client, ttl: ttl)
	}

	static func sendCancel(_ id: String, to mac: TrustedDevice, client: RelayClient, ttl: UInt32) {
		Task { _ = try? await client.send(.apiCancel(id: id), to: mac, ttl: ttl) }
	}

	static func response(for request: URLRequest, status: Int, headers: [String: String]) -> HTTPURLResponse {
		let url = request.url ?? URL(string: "\(RelayAPI.placeholderScheme)://relay/")!
		return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
	}
}

/// The head of a relayed stream, handed from the feeding task to `stream(for:)`.
final class StreamHead: @unchecked Sendable {
	private let lock = NSLock()
	private var result: Result<(Int, [String: String]), Error>?
	private var waiter: CheckedContinuation<(Int, [String: String]), Error>?
	private var complete = false
	private var feeder: Task<Void, Never>?
	private var feederCancelled = false

	func setFeeder(_ task: Task<Void, Never>) {
		let cancelNow: Bool = lock.withLock {
			feeder = task
			return feederCancelled
		}
		if cancelNow { task.cancel() }
	}

	func cancelFeeder() {
		let task: Task<Void, Never>? = lock.withLock {
			feederCancelled = true
			return feeder
		}
		task?.cancel()
	}

	var isComplete: Bool { lock.withLock { complete } }

	func markComplete() { lock.withLock { complete = true } }

	func resolve(status: Int, headers: [String: String]) { settle(.success((status, headers))) }

	func fail(_ error: Error) { settle(.failure(error)) }

	private func settle(_ value: Result<(Int, [String: String]), Error>) {
		let continuation: CheckedContinuation<(Int, [String: String]), Error>? = lock.withLock {
			guard result == nil else { return nil }
			result = value
			defer { waiter = nil }
			return waiter
		}
		continuation?.resume(with: value)
	}

	func wait() async throws -> (Int, [String: String]) {
		try await withCheckedThrowingContinuation { continuation in
			let ready: Result<(Int, [String: String]), Error>? = lock.withLock {
				if let result { return result }
				waiter = continuation
				return nil
			}
			if let ready { continuation.resume(with: ready) }
		}
	}
}
