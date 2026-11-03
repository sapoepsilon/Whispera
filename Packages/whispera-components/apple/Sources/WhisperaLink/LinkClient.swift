import Foundation

public protocol LinkTransport: Sendable {
	func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
	func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse)
}

public struct URLSessionLinkTransport: LinkTransport {
	public let session: URLSession

	public init(session: URLSession = URLSessionLinkTransport.makeSession()) {
		self.session = session
	}

	public static func makeSession() -> URLSession {
		let config = URLSessionConfiguration.ephemeral
		config.requestCachePolicy = .reloadIgnoringLocalCacheData
		config.timeoutIntervalForResource = 7 * 24 * 3600
		config.waitsForConnectivity = false
		return URLSession(configuration: config)
	}

	public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
		return (data, http)
	}

	public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse) {
		let (bytes, response) = try await session.bytes(for: request)
		guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
		let stream = AsyncThrowingStream<UInt8, Error> { continuation in
			let task = Task {
				do {
					for try await byte in bytes { continuation.yield(byte) }
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
		return (stream, http)
	}
}

/// Signed HTTP client for the whispera-link daemon (protocol §4, §5). Every request
/// except health and pair carries the four `X-WL-*` headers; the string to sign is
/// built from the final URL so percent-encoding is exactly what goes on the wire.
public final class LinkClient: @unchecked Sendable {
	public let baseURL: URL
	public let deviceID: String
	public let daemonPubkey: Data
	private let linkKey: LinkSigningKey
	private let transport: LinkTransport
	private let clock: @Sendable () -> Date
	private let lock = NSLock()
	private var clockOffset: Int = 0

	public static let defaultTimeout: TimeInterval = 10
	public static let promptWaitTimeout: TimeInterval = 40
	public static let sseIdleTimeout: TimeInterval = 40

	public init(
		baseURL: URL,
		deviceID: String,
		linkKey: LinkSigningKey,
		daemonPubkey: Data,
		transport: LinkTransport = URLSessionLinkTransport(),
		clock: @escaping @Sendable () -> Date = { Date() }
	) {
		self.baseURL = baseURL
		self.deviceID = deviceID
		self.linkKey = linkKey
		self.daemonPubkey = daemonPubkey
		self.transport = transport
		self.clock = clock
	}

	public var offset: Int {
		lock.lock()
		defer { lock.unlock() }
		return clockOffset
	}

	public func learnServerTime(_ serverTime: Int) {
		let local = Int(clock().timeIntervalSince1970)
		lock.lock()
		clockOffset = serverTime - local
		lock.unlock()
	}

	public var serverNow: Int { Int(clock().timeIntervalSince1970) + offset }

	// MARK: Request building

	public func url(path: String, query: [(String, String)] = []) -> URL {
		var base = baseURL.absoluteString
		while base.hasSuffix("/") { base.removeLast() }
		var string = base + path
		if !query.isEmpty {
			var allowed = CharacterSet.alphanumerics
			allowed.insert(charactersIn: "-._~")
			string += "?" + query.map {
				"\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)"
			}.joined(separator: "&")
		}
		return URL(string: string)!
	}

	public func signedRequest(
		method: String, path: String, query: [(String, String)] = [], body: Data? = nil,
		timeout: TimeInterval = LinkClient.defaultTimeout, nonce: String = LinkCrypto.makeNonce()
	) throws -> URLRequest {
		let url = url(path: path, query: query)
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.timeoutInterval = timeout
		request.cachePolicy = .reloadIgnoringLocalCacheData
		let bodyData = body ?? Data()
		if let body {
			request.httpBody = body
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		let timestamp = String(serverNow)
		let target = LinkCrypto.requestTarget(for: url)
		let message = LinkCrypto.stringToSign(
			method: method, requestTarget: target, body: bodyData, timestamp: timestamp, nonce: nonce,
			deviceID: deviceID)
		let signature = try linkKey.sign(Data(message.utf8))
		request.setValue(deviceID, forHTTPHeaderField: "X-WL-Device")
		request.setValue(timestamp, forHTTPHeaderField: "X-WL-Timestamp")
		request.setValue(nonce, forHTTPHeaderField: "X-WL-Nonce")
		request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-WL-Signature")
		return request
	}

	private func send(
		_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
		timeout: TimeInterval = LinkClient.defaultTimeout, retryOnSkew: Bool = true, retryOnFailover: Bool = true
	) async throws -> Data {
		let request = try signedRequest(method: method, path: path, query: query, body: body, timeout: timeout)
		let failover = transport as? FailoverLinkTransport
		let wentDirect = failover?.path == .direct
		let data: Data
		let response: HTTPURLResponse
		do {
			(data, response) = try await transport.data(for: request)
		} catch where retryOnFailover && method == "GET" && wentDirect && failover?.path == .relay
			&& FailoverLinkTransport.isConnectError(error) && !FailoverLinkTransport.isUndelivered(error)
		{
			// The direct attempt may have reached the Mac (its nonce is spent): a GET is
			// safe to repeat, freshly signed, on the relay the transport switched to.
			return try await send(
				method, path, query: query, body: body, timeout: timeout, retryOnSkew: retryOnSkew,
				retryOnFailover: false)
		} catch let error as URLError where error.code == .timedOut {
			throw LinkError.timedOut("\(method) \(path)")
		} catch let error as LinkError {
			throw error
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			throw LinkError.transport(error)
		}
		guard (200..<300).contains(response.statusCode) else {
			let error = LinkError.decode(status: response.statusCode, body: data)
			if error.code == "auth_clock_skew", let serverTime = error.serverTime, retryOnSkew {
				learnServerTime(serverTime)
				return try await send(
					method, path, query: query, body: body, timeout: timeout, retryOnSkew: false,
					retryOnFailover: retryOnFailover)
			}
			throw error
		}
		return data
	}

	private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			throw LinkError(code: "bad_response", message: "Unexpected response from the Mac: \(error)", status: 200)
		}
	}

	static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return encoder
	}()

	private static func json(_ object: [String: Any]) -> Data {
		(try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
	}

	// MARK: Unauthenticated

	public static func health(baseURL: URL, transport: LinkTransport = URLSessionLinkTransport()) async throws -> LinkHealth {
		var base = baseURL.absoluteString
		while base.hasSuffix("/") { base.removeLast() }
		var request = URLRequest(url: URL(string: base + "/v1/health")!)
		request.timeoutInterval = defaultTimeout
		let data: Data
		let response: HTTPURLResponse
		do {
			(data, response) = try await transport.data(for: request)
		} catch {
			throw LinkError.transport(error)
		}
		guard response.statusCode == 200 else { throw LinkError.decode(status: response.statusCode, body: data) }
		do {
			return try JSONDecoder().decode(LinkHealth.self, from: data)
		} catch {
			throw LinkError(code: "bad_response", message: "That address is not a whispera-link daemon.", status: 200)
		}
	}

	public func health() async throws -> LinkHealth {
		let health = try await LinkClient.health(baseURL: baseURL, transport: transport)
		learnServerTime(health.server_time)
		return health
	}

	// MARK: Devices (§5.3)

	public func me() async throws -> LinkDevice {
		struct Wrapper: Decodable { var device: LinkDevice }
		return try decode(Wrapper.self, try await send("GET", "/v1/devices/me")).device
	}

	public func updateAPNs(token: String?, env: String) async throws -> LinkDevice {
		struct Wrapper: Decodable { var device: LinkDevice }
		var body: [String: Any] = ["env": env]
		body["token"] = token ?? NSNull()
		return try decode(Wrapper.self, try await send("PUT", "/v1/devices/me/apns", body: Self.json(body))).device
	}

	public func unpair() async throws {
		_ = try await send("DELETE", "/v1/devices/me")
	}

	// MARK: Agents (§5.4)

	public func agents() async throws -> AgentList {
		try decode(AgentList.self, try await send("GET", "/v1/agents"))
	}

	public func agent(_ id: String) async throws -> LinkAgent {
		try decode(AgentEnvelope.self, try await send("GET", "/v1/agents/\(LinkCrypto.encodePathSegment(id))")).agent
	}

	public func output(_ id: String, source: String = "recent", lines: Int = 200) async throws -> AgentOutput {
		try decode(
			AgentOutput.self,
			try await send(
				"GET", "/v1/agents/\(LinkCrypto.encodePathSegment(id))/output",
				query: [("source", source), ("lines", String(lines))]))
	}

    public func diff(_ id: String, staged: Bool = false) async throws -> AgentDiff {
        try decode(AgentDiff.self, try await send("GET", "/v1/agents/\(LinkCrypto.encodePathSegment(id))/diff", query: [("staged", staged ? "1" : "0")]))
    }

	public func prompt(_ id: String, text: String, wait: Bool) async throws -> PromptResult {
		var body: [String: Any] = ["text": text]
		if wait { body["wait"] = ["until": ["idle", "done", "blocked"], "timeout_ms": 30000] }
		return try decode(PromptResult.self, try await send(
			"POST", "/v1/agents/\(LinkCrypto.encodePathSegment(id))/prompt", body: Self.json(body),
			timeout: wait ? Self.promptWaitTimeout : Self.defaultTimeout))
	}

	/// Acknowledges delivery without waiting for the agent's turn to finish. Keep the same
	/// submission ID when retrying after a lost response: the Mac returns the stored receipt.
	public func submitPrompt(_ id: String, text: String, submissionID: String, images: [String] = []) async throws -> PromptResult {
		let capabilities = try await capabilities()
		guard capabilities.contains("prompt_receipts") else {
			guard images.isEmpty else { throw LinkError(code: "update_mac", message: "Update Whispera on your Mac to send images.", status: 409) }
			return try await prompt(id, text: text, wait: false)
		}
		return try decode(PromptResult.self, try await send(
			"POST", "/v1/agents/\(LinkCrypto.encodePathSegment(id))/prompt",
			body: Self.json(["text": text, "submission_id": submissionID, "images": images]), timeout: 100))
	}

	public func capabilities() async throws -> [String] {
		struct Capabilities: Decodable { var capabilities: [String]? }
		return try decode(Capabilities.self, try await send("GET", "/v1/health")).capabilities ?? []
	}

	/// Small signed chunks also fit the encrypted relay's envelope limit. An upload ID is
	/// scoped to the paired phone; interrupted/repeated chunks never append duplicate bytes.
	public func uploadImage(_ data: Data, id: String, mimeType: String = "image/jpeg") async throws -> String {
		guard data.count > 0, data.count <= 1_048_576 else {
			throw LinkError(code: "image_size", message: "Images must be at most 1 MB.", status: 413)
		}
		guard try await capabilities().contains("image_uploads") else {
			throw LinkError(code: "update_mac", message: "Update Whispera on your Mac to send images.", status: 409)
		}
		let chunkSize = 24 * 1024
		for offset in stride(from: 0, to: data.count, by: chunkSize) {
			try Task.checkCancellation()
			let chunk = data.subdata(in: offset..<min(offset + chunkSize, data.count))
			_ = try await send("POST", "/v1/images/\(LinkCrypto.encodePathSegment(id))", body: Self.json([
				"mime_type": mimeType, "total_bytes": data.count, "offset": offset, "data": chunk.base64EncodedString()
			]), timeout: 30)
		}
		return id
	}

	/// Sends key names (`esc`, `enter`, `ctrl+c`, …), 1–32 of them.
    public struct MacRecipe: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
    }
    public struct RecipeCatalog: Codable, Sendable, Equatable {
        public let recipes: [MacRecipe]
        public let ready: Bool
        public let message: String?
    }
    public func recipes() async throws -> RecipeCatalog {
        try decode(RecipeCatalog.self, try await send("GET", "/v1/recipes"))
    }
    public func runRecipe(_ id: String, text: String) async throws -> String {
        struct Reply: Decodable { let text: String }
        return try decode(Reply.self, try await send("POST", "/v1/recipes/\(LinkCrypto.encodePathSegment(id))/run", body: Self.json(["text": text]), timeout: 95)).text
    }

	@discardableResult
	public func keys(_ id: String, keys: [String]) async throws -> KeysResult {
		try decode(
			KeysResult.self,
			try await send(
				"POST", "/v1/agents/\(LinkCrypto.encodePathSegment(id))/keys", body: Self.json(["keys": keys])))
	}

	@discardableResult
	public func interrupt(_ id: String, key: InterruptKey = .esc) async throws -> KeysResult {
		try decode(
			KeysResult.self,
			try await send(
				"POST", "/v1/agents/\(LinkCrypto.encodePathSegment(id))/interrupt", body: Self.json(["key": key.rawValue])))
	}

	/// Stops the agent (the Mac sends `ctrl+c` twice).
	@discardableResult
	public func stop(_ id: String) async throws -> StopResult {
		try decode(StopResult.self, try await send("POST", "/v1/agents/\(LinkCrypto.encodePathSegment(id))/stop", body: Data("{}".utf8)))
	}

	/// Starts an agent and returns it once herdr sees it ready.
	public func startAgent(_ request: StartAgentRequest) async throws -> LinkAgent {
		let timeout = request.timeout_ms.map { max(Self.defaultTimeout, TimeInterval($0) / 1000 + 10) } ?? Self.promptWaitTimeout
		return try decode(
			AgentEnvelope.self,
			try await send("POST", "/v1/agents", body: try Self.encoder.encode(request), timeout: timeout)
		).agent
	}

	// MARK: Push text

	/// Tells the Mac what this phone's approval pushes may say.
	public func setPushText(_ mode: PushTextMode) async throws {
		_ = try await send("PUT", "/v1/devices/me/push", body: Self.json(["text": mode.rawValue]))
	}

	// MARK: Approvals (§5.6)

	public func pendingApprovals() async throws -> [PendingApproval] {
		try decode(PendingApprovals.self, try await send("GET", "/v1/approvals/pending")).approvals
	}

	public func approval(_ id: String) async throws -> ApprovalDetail {
		try decode(ApprovalDetail.self, try await send("GET", "/v1/approvals/\(LinkCrypto.encodePathSegment(id))"))
	}

	public func approve(_ id: String, signature: Data) async throws -> DecisionResult {
		let body = Self.json(["decision": "approve", "signature": signature.base64EncodedString()])
		return try decode(
			DecisionResult.self,
			try await send("POST", "/v1/approvals/\(LinkCrypto.encodePathSegment(id))/decision", body: body))
	}

	/// A deny is signed like an approve (`WL1-DENY\n` + canonical bytes, approve key): the
	/// Mac refuses an unsigned one, so a stray or rogue device cannot deny every request.
	public func deny(_ id: String, signature: Data) async throws -> DecisionResult {
		let body = Self.json(["decision": "deny", "signature": signature.base64EncodedString()])
		return try decode(
			DecisionResult.self,
			try await send("POST", "/v1/approvals/\(LinkCrypto.encodePathSegment(id))/decision", body: body))
	}

	// MARK: Events (§5.5)

	/// SSE with `Last-Event-ID` resume and reconnect backoff 1, 2, 4 … 30 s. No byte for
	/// 40 s (the daemon pings every 15 s) counts as a dead stream. `.connected` and
	/// `.disconnected` are yielded so the caller can switch to its poll fallback.
	public func events() -> AsyncThrowingStream<LinkEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				var lastEventID: String?
				var backoff: UInt64 = 1
				while !Task.isCancelled {
					do {
						var request = try signedRequest(method: "GET", path: "/v1/events", timeout: 7 * 24 * 3600)
						request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
						if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
						let (bytes, response) = try await transport.stream(for: request)
						guard response.statusCode == 200 else {
							var body = Data()
							for try await byte in bytes {
								body.append(byte)
								if body.count > 8192 { break }
							}
							let error = LinkError.decode(status: response.statusCode, body: body)
							if let serverTime = error.serverTime { learnServerTime(serverTime) }
							if error.code == "auth_revoked" || error.code == "auth_unknown_device" {
								continuation.finish(throwing: error)
								return
							}
							throw error
						}
						continuation.yield(.connected)
						backoff = 1
						try await readFrames(bytes, continuation: continuation) { id in lastEventID = id }
						continuation.yield(.disconnected("stream closed"))
					} catch is CancellationError {
						break
					} catch {
						if Task.isCancelled { break }
						continuation.yield(.disconnected((error as? LinkError)?.message ?? error.localizedDescription))
					}
					try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
					backoff = min(backoff * 2, 30)
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private func readFrames(
		_ bytes: AsyncThrowingStream<UInt8, Error>,
		continuation: AsyncThrowingStream<LinkEvent, Error>.Continuation,
		onID: @escaping (String) -> Void
	) async throws {
		let watchdog = SSEWatchdog(timeout: Self.sseIdleTimeout)
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask {
				var parser = LinkSSEParser()
				for try await byte in bytes {
					await watchdog.touch()
					if let frame = parser.consume(byte) {
						if let id = frame.id { onID(id) }
						if let event = LinkSSEParser.event(from: frame) {
							if case .hello(_, let serverTime?) = event { self.learnServerTime(serverTime) }
							continuation.yield(event)
						}
					}
				}
			}
			group.addTask {
				try await watchdog.waitForStall()
				throw LinkError.timedOut("event stream")
			}
			try await group.next()
			group.cancelAll()
		}
	}
}

public actor SSEWatchdog {
	private var last = Date()
	private let timeout: TimeInterval

	public init(timeout: TimeInterval) {
		self.timeout = timeout
	}

	public func touch() {
		last = Date()
	}

	public func waitForStall() async throws {
		while true {
			let idle = Date().timeIntervalSince(last)
			if idle >= timeout { return }
			try await Task.sleep(nanoseconds: UInt64((timeout - idle) * 1_000_000_000))
		}
	}
}
