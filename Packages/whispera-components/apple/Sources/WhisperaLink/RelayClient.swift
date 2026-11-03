import Foundation

public enum RelayError: Error, Equatable, Sendable {
	/// A device record's link key does not hash to its advertised `link_fp`.
	case fingerprintMismatch(String)
	/// The recipient has published no agreement key, so nothing can be sealed to it.
	case noAgreementKey(String)
	/// `kem_pubkey` is not a `KEMKeyRecord`, or its link-key signature is wrong.
	case badKEMRecord
	/// The sender of a relayed message is not among this account's devices.
	case unknownSender(String)
	case revoked(String)
}

/// The Whispera backend's device registry and E2E relay, matching the Rust server's
/// routes (`crates/server/src/lib.rs`, whispera-backend PR #4) exactly:
///
/// | Call | Auth | Request | Response |
/// | --- | --- | --- | --- |
/// | `GET /v1/health` | none | — | `BackendHealth` |
/// | `POST /v1/devices` | account bearer | `RegisterDeviceRequest` | `201 PublicDevice` |
/// | `GET /v1/devices` | account bearer | — | `DeviceList` |
/// | `DELETE /v1/devices/{id}` | account bearer | — | `204` |
/// | `GET /v1/device/peers` | WL1 | — | `DeviceList` (the caller's account) |
/// | `PUT /v1/device/apns` | WL1 | `UpdateApnsRequest` | `PublicDevice` (the caller) |
/// | `POST /v1/relay/send` | WL1 | `RelaySendRequest` | `201 RelaySendResponse` |
/// | `GET /v1/relay/messages?after=&limit=&wait=` | WL1 | — | `RelayFetchResponse` (long poll) |
/// | `POST /v1/relay/ack` | WL1 | `RelayAckRequest` | `RelayAckResponse` |
/// | `GET /v1/relay/stream?after=` | WL1 | — | SSE, one `message` event per `RelayMessage`, `id` = seq |
/// | `POST /v1/notify` | WL1 | `NotifyRequest` | `NotifyResponse` |
///
/// The account-bearer calls are `static`: they belong to whoever is signed in, not to
/// a device. Everything on an instance is WL1-signed by this device's link key.
public final class RelayClient: @unchecked Sendable {
	public let baseURL: URL
	public let deviceID: String
	let linkKey: LinkSigningKey
	private let transport: LinkTransport
	private let clock: @Sendable () -> Date
	private let lock = NSLock()
	private var clockOffset: Int64 = 0

	public static let defaultTimeout: TimeInterval = 15
	/// The server's `max_wait_s`: a longer wait is clamped there anyway.
	public static let maxWait = 30
	/// The server pings every 15 s; this long without a byte is a dead stream.
	public static let streamIdleTimeout: TimeInterval = 40

	public init(
		baseURL: URL, deviceID: String, linkKey: LinkSigningKey, transport: LinkTransport = URLSessionLinkTransport(),
		clock: @escaping @Sendable () -> Date = { Date() }
	) {
		self.baseURL = baseURL
		self.deviceID = deviceID
		self.linkKey = linkKey
		self.transport = transport
		self.clock = clock
	}

	public var serverNow: Int64 {
		lock.lock()
		defer { lock.unlock() }
		return Int64(clock().timeIntervalSince1970) + clockOffset
	}

	public func learnServerTime(_ serverTime: Int64) {
		let local = Int64(clock().timeIntervalSince1970)
		lock.lock()
		clockOffset = serverTime - local
		lock.unlock()
	}

	// MARK: Unauthenticated

	public static func health(baseURL: URL, transport: LinkTransport = URLSessionLinkTransport()) async throws -> BackendHealth {
		var request = URLRequest(url: url(baseURL, "/v1/health"))
		request.timeoutInterval = defaultTimeout
		return try decode(BackendHealth.self, try await perform(request, transport: transport))
	}

	// MARK: Account bearer

	/// Registers a device's public keys under the signed-in account and returns its
	/// record, whose `device_id` every WL1 call then signs as.
	public static func register(
		baseURL: URL, accountToken: String, _ body: RegisterDeviceRequest,
		transport: LinkTransport = URLSessionLinkTransport()
	) async throws -> PublicDevice {
		let request = accountRequest(baseURL, "POST", "/v1/devices", token: accountToken, body: try encoder.encode(body))
		return try decode(PublicDevice.self, try await perform(request, transport: transport))
	}

	/// Every device of the signed-in account, revoked ones included.
	public static func devices(
		baseURL: URL, accountToken: String, transport: LinkTransport = URLSessionLinkTransport()
	) async throws -> [PublicDevice] {
		let request = accountRequest(baseURL, "GET", "/v1/devices", token: accountToken)
		return try decode(DeviceList.self, try await perform(request, transport: transport)).devices
	}

	/// Revokes a device of the signed-in account everywhere; its open long polls and
	/// streams end.
	public static func revoke(
		baseURL: URL, accountToken: String, deviceID: String, transport: LinkTransport = URLSessionLinkTransport()
	) async throws {
		let request = accountRequest(
			baseURL, "DELETE", "/v1/devices/\(LinkCrypto.encodePathSegment(deviceID))", token: accountToken)
		_ = try await perform(request, transport: transport)
	}

	// MARK: Device (WL1)

	/// This device's account's devices — the list it seals to and verifies senders by.
	public func peers() async throws -> [PublicDevice] {
		try Self.decode(DeviceList.self, try await send("GET", "/v1/device/peers")).devices
	}

	/// Sets (or, with nil, clears) this device's APNs token, so `notify` can wake it.
	@discardableResult
	public func updateAPNs(_ registration: ApnsRegistration?) async throws -> PublicDevice {
		try Self.decode(
			PublicDevice.self,
			try await send("PUT", "/v1/device/apns", body: try Self.encoder.encode(UpdateApnsRequest(apns: registration))))
	}

	/// `updateAPNs(ApnsRegistration(token:env:))`. `token` is the hex device token.
	@discardableResult
	public func updateAPNs(token: String, env: ApnsEnv) async throws -> PublicDevice {
		try await updateAPNs(ApnsRegistration(token: token, env: env))
	}

	public func send(_ body: RelaySendRequest) async throws -> RelaySendResponse {
		try Self.decode(RelaySendResponse.self, try await send("POST", "/v1/relay/send", body: try Self.encoder.encode(body)))
	}

	/// Seals `plaintext` to `recipient` and sends it.
	public func send(_ plaintext: Data, to recipient: PublicDevice, ttl: UInt32? = nil) async throws -> RelaySendResponse {
		guard !recipient.isRevoked else { throw RelayError.revoked(recipient.device_id) }
		guard let key = try recipient.verifiedAgreementKey() else { throw RelayError.noAgreementKey(recipient.device_id) }
		let envelope = try SealedEnvelope.seal(
			plaintext, from: deviceID, signingKey: linkKey, to: recipient.device_id, recipientKey: key, now: serverNow)
		return try await send(RelaySendRequest(to: recipient.device_id, ciphertext: envelope.base64, ttl_s: ttl))
	}

	/// One fetch. With `wait > 0` it is a long poll: the server answers as soon as a
	/// message with `seq > after` is queued, or with `[]` after `wait` seconds.
	public func messages(after: Int64 = 0, limit: Int? = nil, wait: Int = 0) async throws -> [RelayMessage] {
		let wait = max(0, min(wait, Self.maxWait))
		var query: [(String, String)] = [("after", String(after))]
		if let limit { query.append(("limit", String(limit))) }
		if wait > 0 { query.append(("wait", String(wait))) }
		let data = try await send(
			"GET", "/v1/relay/messages", query: query, timeout: TimeInterval(wait) + Self.defaultTimeout)
		return try Self.decode(RelayFetchResponse.self, data).messages
	}

	/// Deletes this device's messages with `seq <= upTo`; returns how many went.
	@discardableResult
	public func ack(upTo seq: Int64) async throws -> UInt64 {
		try Self.decode(
			RelayAckResponse.self,
			try await send("POST", "/v1/relay/ack", body: try Self.encoder.encode(RelayAckRequest(up_to_seq: seq)))
		).deleted
	}

	/// A content-free push to another device of the account.
	public func notify(_ deviceID: String) async throws -> NotifyResponse {
		try Self.decode(
			NotifyResponse.self,
			try await send("POST", "/v1/notify", body: try Self.encoder.encode(NotifyRequest(device_id: deviceID))))
	}

	/// An approval push: `kind` with its `request_id`, and for a named approval the
	/// WLP1 `sealed` text the phone's extension opens. The backend never sees text.
	public func notify(
		_ deviceID: String, kind: NotifyKind?, requestID: String? = nil, sealed: String? = nil
	) async throws -> NotifyResponse {
		let body = NotifyRequest(device_id: deviceID, kind: kind?.rawValue, request_id: requestID, sealed: sealed)
		return try Self.decode(NotifyResponse.self, try await send("POST", "/v1/notify", body: try Self.encoder.encode(body)))
	}

	/// The SSE alternative to polling: every message after `after`, then each new one
	/// as it arrives. Ends when the server closes the stream (it does on revocation);
	/// throws on a refused request or a stream silent for `streamIdleTimeout`.
	/// Reconnecting is the caller's call — resume from the last `seq` it handled.
	public func stream(after: Int64 = 0) -> AsyncThrowingStream<RelayMessage, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					var request = try signedRequest(
						method: "GET", path: "/v1/relay/stream", query: [("after", String(after))], timeout: 7 * 24 * 3600)
					request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
					let (bytes, response) = try await transport.stream(for: request)
					guard response.statusCode == 200 else {
						var body = Data()
						for try await byte in bytes {
							body.append(byte)
							if body.count > 8192 { break }
						}
						throw LinkError.decode(status: response.statusCode, body: body)
					}
					let watchdog = SSEWatchdog(timeout: Self.streamIdleTimeout)
					try await withThrowingTaskGroup(of: Void.self) { group in
						group.addTask {
							var parser = LinkSSEParser()
							for try await byte in bytes {
								await watchdog.touch()
								guard let frame = parser.consume(byte), frame.event == "message" else { continue }
								let message = try JSONDecoder().decode(RelayMessage.self, from: Data(frame.data.utf8))
								continuation.yield(message)
							}
						}
						group.addTask {
							try await watchdog.waitForStall()
							throw LinkError.timedOut("relay stream")
						}
						try await group.next()
						group.cancelAll()
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Opens a relayed message: finds its sender among `peers`, checks the envelope's
	/// sender is the relay's `from`, then `SealedEnvelope.open`.
	public func open(_ message: RelayMessage, peers: [PublicDevice], agreementKey: LinkAgreementKey) throws -> Data {
		guard let sender = peers.first(where: { $0.device_id == message.from }) else {
			throw RelayError.unknownSender(message.from)
		}
		guard !sender.isRevoked else { throw RelayError.revoked(sender.device_id) }
		let envelope = try SealedEnvelope(base64: message.ciphertext)
		guard envelope.senderID == message.from else { throw EnvelopeError.badSignature }
		return try envelope.open(
			as: deviceID, agreementKey: agreementKey, senderKey: try sender.verifiedLinkKey(), now: serverNow)
	}

	// MARK: Signing and transport

	public func signedRequest(
		method: String, path: String, query: [(String, String)] = [], body: Data? = nil,
		timeout: TimeInterval = RelayClient.defaultTimeout, nonce: String = LinkCrypto.makeNonce()
	) throws -> URLRequest {
		var url = Self.url(baseURL, path)
		if !query.isEmpty {
			url = URL(string: url.absoluteString + "?" + query.map {
				"\(LinkCrypto.encodePathSegment($0.0))=\(LinkCrypto.encodePathSegment($0.1))"
			}.joined(separator: "&"))!
		}
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.timeoutInterval = timeout
		request.cachePolicy = .reloadIgnoringLocalCacheData
		if let body {
			request.httpBody = body
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		let headers = try SignedHeaders.sign(
			key: linkKey, deviceID: deviceID, method: method, target: LinkCrypto.requestTarget(for: url),
			body: body ?? Data(), timestamp: serverNow, nonce: nonce)
		headers.apply(to: &request)
		return request
	}

	/// Waits before each retry of a request the relay refused as busy (`rate_limited`, or the
	/// recipient's `mailbox_full` while it drains). The relay did nothing with it, so the
	/// same call, freshly signed, is safe to repeat.
	static let busyRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4]

	private func send(
		_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
		timeout: TimeInterval = RelayClient.defaultTimeout, retryOnSkew: Bool = true, busyRetry: Int = 0
	) async throws -> Data {
		let request = try signedRequest(method: method, path: path, query: query, body: body, timeout: timeout)
		do {
			return try await Self.perform(request, transport: transport)
		} catch let error as LinkError where error.errorCode == .authClockSkew && retryOnSkew {
			guard let serverTime = error.serverTime else { throw error }
			learnServerTime(Int64(serverTime))
			return try await send(method, path, query: query, body: body, timeout: timeout, retryOnSkew: false, busyRetry: busyRetry)
		} catch let error as LinkError
			where [.rateLimited, .mailboxFull].contains(error.errorCode) && busyRetry < Self.busyRetryDelays.count
		{
			try await Task.sleep(nanoseconds: UInt64(Self.busyRetryDelays[busyRetry] * 1_000_000_000))
			return try await send(
				method, path, query: query, body: body, timeout: timeout, retryOnSkew: retryOnSkew, busyRetry: busyRetry + 1)
		}
	}

	static func accountRequest(_ base: URL, _ method: String, _ path: String, token: String, body: Data? = nil) -> URLRequest {
		var request = URLRequest(url: url(base, path))
		request.httpMethod = method
		request.timeoutInterval = defaultTimeout
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		if let body {
			request.httpBody = body
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		return request
	}

	static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return encoder
	}()

	static func url(_ base: URL, _ path: String) -> URL {
		var string = base.absoluteString
		while string.hasSuffix("/") { string.removeLast() }
		return URL(string: string + path)!
	}

	static func perform(_ request: URLRequest, transport: LinkTransport) async throws -> Data {
		let data: Data
		let response: HTTPURLResponse
		do {
			(data, response) = try await transport.data(for: request)
		} catch let error as URLError where error.code == .timedOut {
			throw LinkError.timedOut("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
		} catch let error as LinkError {
			throw error
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			throw LinkError(code: "unreachable", message: "Couldn't reach the relay: \(error.localizedDescription)", status: 0)
		}
		guard (200..<300).contains(response.statusCode) else {
			throw LinkError.decode(status: response.statusCode, body: data)
		}
		return data
	}

	static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			throw LinkError.badResponse("Unexpected response from the relay: \(error)")
		}
	}
}
