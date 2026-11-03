import Foundation

/// The single inbox pump for one `RelayClient`: one cursor, one ack, no matter how
/// many parts of an app read relayed messages.
///
/// It long-polls `GET /v1/relay/messages` (`wait`, 25 s by default), opens each
/// message with `openLinkMessage` against the account's current devices, dispatches
/// it, then acks the batch and saves the cursor. Routing:
///
/// * `api_response` → the waiter registered for that request id (a
///   `RelayLinkTransport` call), only when the sender is the device it is waiting on;
///   unknown ids, wrong senders and duplicates are dropped.
/// * everything else → `handler` (account messages: `link_offer`,
///   `approve_confirmed`, `unpaired`; on the Mac also `api_request` / `api_cancel`).
///
/// A message from a device the snapshot does not know makes the mailbox ask the
/// devices provider to refresh once per batch, as the Mac's AccountLink does — a
/// phone that just registered is not in a stale list yet. A message that still does
/// not open is dropped (and acked): nothing about it can become valid later.
///
/// `handler` is awaited before the batch is acked, so it should return promptly and
/// hand long work (a relayed SSE stream on the Mac) to its own task.
public actor RelayMailbox {
	/// `refresh == false`: the current snapshot. `true`: fetch the list again.
	public typealias DevicesProvider = @Sendable (_ refresh: Bool) async throws -> AccountDevices
	public typealias Handler = @Sendable (ReceivedLinkMessage) async -> Void

	/// What the pump reports besides messages, for logs and tests.
	public enum Event: Sendable {
		/// A message that did not open or decode, dropped (and acked).
		case rejected(seq: Int64, from: String, error: String)
		/// An `api_response` nobody waits for, or from the wrong sender.
		case unroutedResponse(id: String, from: String)
		/// A fetch or devices refresh failed; the pump retries with backoff.
		case fetchFailed(String)
		/// The devices provider was asked to refresh for an unknown sender.
		case refreshedDevices(unknownSender: String)
	}

	public nonisolated let client: RelayClient
	private let agreementKey: LinkAgreementKey
	private let devicesProvider: DevicesProvider
	private let wait: Int
	private let idleDelay: TimeInterval
	private let loadCursor: @Sendable () async -> Int64
	private let saveCursor: @Sendable (Int64) async -> Void
	private var handler: Handler?
	private var onEvent: (@Sendable (Event) -> Void)?

	private var cursor: Int64?
	private var pumpTask: Task<Void, Never>?
	private var pumping = false
	private var waiters: [String: Waiter] = [:]

	private struct Waiter {
		let senderID: String
		let continuation: AsyncThrowingStream<RelayAPIResponse, Error>.Continuation
	}

	/// The server clamps longer waits.
	public static let defaultWait = 25

	/// - Parameters:
	///   - wait: long-poll seconds per fetch (`0` = plain fetch; then `idleDelay`
	///     paces the loop).
	///   - idleDelay: pause after an empty fetch. Zero with a long poll.
	///   - loadCursor / saveCursor: persist the last handled `seq` across launches.
	public init(
		client: RelayClient, agreementKey: LinkAgreementKey, devices: @escaping DevicesProvider,
		wait: Int = RelayMailbox.defaultWait, idleDelay: TimeInterval = 0,
		loadCursor: @escaping @Sendable () async -> Int64 = { 0 },
		saveCursor: @escaping @Sendable (Int64) async -> Void = { _ in },
		handler: Handler? = nil
	) {
		self.client = client
		self.agreementKey = agreementKey
		devicesProvider = devices
		self.wait = wait
		self.idleDelay = idleDelay
		self.loadCursor = loadCursor
		self.saveCursor = saveCursor
		self.handler = handler
	}

	public func setHandler(_ handler: Handler?) {
		self.handler = handler
	}

	public func setEventObserver(_ observer: (@Sendable (Event) -> Void)?) {
		onEvent = observer
	}

	/// The account's devices as the mailbox sees them (`refresh` re-fetches).
	public func devices(refresh: Bool = false) async throws -> AccountDevices {
		try await devicesProvider(refresh)
	}

	public var isRunning: Bool { pumpTask != nil }

	/// The last handled `seq` (after `start` or a `pumpOnce`).
	public var currentCursor: Int64? { cursor }

	// MARK: Pump

	public func start() {
		guard pumpTask == nil else { return }
		pumpTask = Task { [weak self] in await self?.run() }
	}

	/// Stops the pump. Waiting transports fail with `RelayAPIError.mailboxStopped`.
	public func stop() {
		pumpTask?.cancel()
		pumpTask = nil
		let all = waiters
		waiters.removeAll()
		for waiter in all.values { waiter.continuation.finish(throwing: RelayAPIError.mailboxStopped) }
	}

	private func run() async {
		var backoff: TimeInterval = 1
		while !Task.isCancelled {
			do {
				let count = try await pumpOnce(wait: wait)
				backoff = 1
				if count == 0, idleDelay > 0 { try await Task.sleep(nanoseconds: UInt64(idleDelay * 1_000_000_000)) }
			} catch {
				if Task.isCancelled || error is CancellationError { break }
				onEvent?(.fetchFailed((error as? LinkError)?.message ?? "\(error)"))
				if let link = error as? LinkError, link.errorCode == .authRevoked || link.errorCode == .authUnknownDevice {
					break
				}
				try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
				backoff = min(backoff * 2, 30)
			}
		}
	}

	/// One fetch → open → dispatch → ack round; returns how many messages came. The
	/// running pump calls this; tests and a host without a pump can call it directly.
	@discardableResult
	public func pumpOnce(wait: Int = 0) async throws -> Int {
		guard !pumping else { return 0 }
		pumping = true
		defer { pumping = false }
		if cursor == nil { cursor = await loadCursor() }
		let after = cursor ?? 0
		let messages = try await client.messages(after: after, wait: wait)
		guard !messages.isEmpty else { return 0 }
		var devices = try await devicesProvider(false)
		var refreshed = false
		var last = after
		for relayed in messages.sorted(by: { $0.seq < $1.seq }) where relayed.seq > after {
			last = max(last, relayed.seq)
			if devices.peer(relayed.from) == nil, !refreshed {
				refreshed = true
				onEvent?(.refreshedDevices(unknownSender: relayed.from))
				if let fresh = try? await devicesProvider(true) { devices = fresh }
			}
			let received: ReceivedLinkMessage
			do {
				received = try client.openLinkMessage(relayed, devices: devices, agreementKey: agreementKey)
			} catch {
				onEvent?(.rejected(seq: relayed.seq, from: relayed.from, error: "\(error)"))
				continue
			}
			await dispatch(received)
		}
		_ = try? await client.ack(upTo: last)
		cursor = last
		await saveCursor(last)
		return messages.count
	}

	private func dispatch(_ received: ReceivedLinkMessage) async {
		if case .apiResponse(let frame) = received.message {
			guard let waiter = waiters[frame.id], waiter.senderID == received.sender.id else {
				onEvent?(.unroutedResponse(id: frame.id, from: received.sender.id))
				return
			}
			waiter.continuation.yield(frame)
			return
		}
		await handler?(received)
	}

	// MARK: Waiters

	/// Registers for the `api_response` frames of request `id` from `senderID`.
	/// Register before sending the request. Ending the iteration (or cancelling the
	/// iterating task) unregisters.
	public func responses(id: String, from senderID: String) -> AsyncThrowingStream<RelayAPIResponse, Error> {
		let (stream, continuation) = AsyncThrowingStream<RelayAPIResponse, Error>.makeStream()
		waiters[id] = Waiter(senderID: senderID, continuation: continuation)
		continuation.onTermination = { [weak self] _ in
			Task { await self?.removeWaiter(id: id) }
		}
		return stream
	}

	public func removeWaiter(id: String) {
		waiters.removeValue(forKey: id)?.continuation.finish()
	}

	/// How many requests are waiting (tests).
	public var waiterCount: Int { waiters.count }
}
