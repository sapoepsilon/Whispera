import Foundation
import WhisperaLink

/// One LinkAPI request, however it arrived: a direct HTTP connection (`HTTPExchange`) or an
/// `api_request` over the account relay (`RelayExchange`). `LinkAPI.handle` only sees this.
protocol LinkExchange: AnyObject, Sendable {
	var method: String { get }
	/// Path + query exactly as signed.
	var target: String { get }
	var path: String { get }
	var query: String { get }
	/// The rate-limit key: the peer address, or `relay:<sender>` for a relayed request.
	var remoteHost: String { get }
	var headerDictionary: [String: String] { get }
	/// The status sent so far, 0 before any.
	var status: Int { get }
	/// The relay sender's account device id; nil for a direct request.
	var relaySender: String? { get }
	var isAlive: Bool { get }

	func header(_ name: String) -> String?
	func readBody(_ count: Int, timeout: TimeInterval) throws -> Data
	func sendContinueIfExpected()
	func respond(_ status: Int, contentType: String, headers: [(String, String)], body: Data)
	func beginStream(_ status: Int, headers: [(String, String)]) throws
	func write(_ data: Data, timeout: TimeInterval) throws
	func close()
}

extension LinkExchange {
	func respond(_ status: Int, headers: [(String, String)] = [], body: Data) {
		respond(status, contentType: "application/json", headers: headers, body: body)
	}

	func write(_ data: Data) throws {
		try write(data, timeout: 60)
	}

	func readBody(_ count: Int) throws -> Data {
		try readBody(count, timeout: 30)
	}
}

extension HTTPExchange: LinkExchange {
	var relaySender: String? { nil }
}

/// A LinkAPI request that came over the relay. Responses leave as sealed `api_response`
/// frames, in order, each `write` waiting until its frames were handed to the relay (the same
/// back-pressure a socket gives). A streamed response ends after `streamLifetime`, when the
/// phone sends `api_cancel`, or when the ingress evicts it.
final class RelayExchange: LinkExchange, @unchecked Sendable {
	typealias Send = @Sendable ([LinkMessage]) async throws -> Void

	let request: RelayAPIRequest
	let sender: String
	let method: String
	let target: String
	let path: String
	let query: String
	let headerDictionary: [String: String]
	let started = Date()
	private let send: Send
	private let streamLifetime: TimeInterval
	private let sendLock = NSLock()
	private let lock = NSLock()
	private var writer: RelayAPIStreamWriter
	private var sentStatus = 0
	private var failed = false
	private var cancelledByPhone = false
	private var streaming = false
	private var finished = false
	private var deadline: Date?
	/// Called once when the response turns into a stream (the ingress counts streams).
	var onStreamStart: ((RelayExchange) -> Void)?

	init(request: RelayAPIRequest, sender: String, streamLifetime: TimeInterval, send: @escaping Send) {
		self.request = request
		self.sender = sender
		self.send = send
		self.streamLifetime = streamLifetime
		method = request.method
		target = request.target
		path = request.path
		query = request.query ?? ""
		var headers = request.headers
		// The relay carries the body whole; LinkAPI's body rules read the length from here.
		headers["Content-Length"] = String(request.body.count)
		headerDictionary = headers
		writer = RelayAPIStreamWriter(id: request.id)
	}

	var remoteHost: String { "relay:" + sender }
	var relaySender: String? { sender }

	var status: Int {
		lock.lock()
		defer { lock.unlock() }
		return sentStatus
	}

	var isStreaming: Bool {
		lock.lock()
		defer { lock.unlock() }
		return streaming
	}

	var isAlive: Bool {
		lock.lock()
		defer { lock.unlock() }
		return !failed && !finished && (deadline.map { Date() < $0 } ?? true)
	}

	func header(_ name: String) -> String? {
		headerDictionary.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
	}

	func readBody(_ count: Int, timeout: TimeInterval) throws -> Data {
		guard count <= request.body.count else { throw HTTPExchange.ConnectionGone() }
		return request.body.prefix(count)
	}

	func sendContinueIfExpected() {}

	func respond(_ status: Int, contentType: String, headers: [(String, String)], body: Data) {
		lock.lock()
		guard sentStatus == 0, !failed else {
			lock.unlock()
			return
		}
		sentStatus = status
		finished = true
		lock.unlock()
		var fields = ["Content-Type": contentType]
		for (name, value) in headers { fields[name] = value }
		sendLock.lock()
		let frames = writer.head(status: status, headers: fields, body: body, final: true)
		sendLock.unlock()
		_ = deliver(frames, timeout: 30)
	}

	func beginStream(_ status: Int, headers: [(String, String)]) throws {
		lock.lock()
		guard sentStatus == 0, !failed else {
			lock.unlock()
			throw HTTPExchange.ConnectionGone()
		}
		sentStatus = status
		streaming = true
		deadline = Date().addingTimeInterval(streamLifetime)
		lock.unlock()
		onStreamStart?(self)
		var fields: [String: String] = [:]
		for (name, value) in headers { fields[name] = value }
		sendLock.lock()
		let frames = writer.head(status: status, headers: fields, body: Data(), final: false)
		sendLock.unlock()
		guard deliver(frames, timeout: 30) else { throw HTTPExchange.ConnectionGone() }
	}

	func write(_ data: Data, timeout: TimeInterval) throws {
		guard isAlive, isStreaming else { throw HTTPExchange.ConnectionGone() }
		sendLock.lock()
		let frames = writer.write(data)
		sendLock.unlock()
		guard deliver(frames, timeout: timeout) else { throw HTTPExchange.ConnectionGone() }
	}

	/// Ends a stream: the final frame unless the phone cancelled it. Idempotent.
	func close() {
		lock.lock()
		let sendFinal = streaming && !cancelledByPhone
		finished = true
		lock.unlock()
		guard sendFinal else { return }
		sendLock.lock()
		let frame = writer.isFinished ? nil : writer.finish()
		sendLock.unlock()
		if let frame { _ = deliver([frame], timeout: 10, ignoringFailure: true) }
	}

	/// Stops the exchange: the handler sees `isAlive == false` and its next write throws.
	/// `byPhone`: the phone sent `api_cancel`, so no final frame goes back.
	func cancel(byPhone: Bool) {
		lock.lock()
		failed = true
		if byPhone { cancelledByPhone = true }
		lock.unlock()
	}

	/// Hands frames to the relay in order; false once the relay refused or timed out.
	private func deliver(_ frames: [RelayAPIResponse], timeout: TimeInterval, ignoringFailure: Bool = false) -> Bool {
		guard !frames.isEmpty else { return true }
		lock.lock()
		let dead = failed && !ignoringFailure
		lock.unlock()
		if dead { return false }
		let messages = frames.map(LinkMessage.apiResponse)
		let done = DispatchSemaphore(value: 0)
		let outcome = SendOutcome()
		let send = self.send
		Task {
			do {
				try await send(messages)
				outcome.ok = true
			} catch {
				outcome.ok = false
			}
			done.signal()
		}
		let ok = done.wait(timeout: .now() + timeout) == .success && outcome.ok
		if !ok {
			lock.lock()
			failed = true
			lock.unlock()
		}
		return ok
	}

	private final class SendOutcome: @unchecked Sendable {
		var ok = false
	}
}

/// The Mac's side of the relayed LinkAPI (step 12): takes `api_request` / `api_cancel` from the
/// account mailbox, runs each request through LinkAPI on a thread of its own (the relay poll
/// never waits on a handler), and keeps at most `maxStreamsPerPhone` relayed streams per phone.
public final class RelayIngress: @unchecked Sendable {
	static let maxStreamsPerPhone = 4
	static let defaultStreamLifetime: TimeInterval = 600

	private let devices: DeviceRegistry
	private let log: OpsLog
	let streamLifetime: TimeInterval
	private let lock = NSLock()
	private var handler: ((LinkExchange) -> Void)?
	private var active: [String: RelayExchange] = [:]
	private var streams: [String: [RelayExchange]] = [:]

	init(devices: DeviceRegistry, log: OpsLog = .null, streamLifetime: TimeInterval = defaultStreamLifetime) {
		self.devices = devices
		self.log = log
		self.streamLifetime = streamLifetime
	}

	func setHandler(_ handler: @escaping (LinkExchange) -> Void) {
		lock.lock()
		self.handler = handler
		lock.unlock()
	}

	private static func key(_ sender: String, _ id: String) -> String { sender + "|" + id }

	/// An `api_request` from `sender`, already opened and verified by the mailbox.
	func accept(_ request: RelayAPIRequest, sender: TrustedDevice, send: @escaping RelayExchange.Send) {
		guard sender.platform == .ios else {
			log("relay.rejected", ["device": sender.id, "detail": "not an iPhone"])
			return
		}
		let refusal: APIError?
		switch devices.get(sender.id) {
		case .some(let record) where record.origin == .account && !record.isRevoked: refusal = nil
		case .some(let record) where record.isRevoked: refusal = APIError(401, "auth_revoked", "device has been revoked")
		default: refusal = APIError(401, "auth_unknown_device", "unknown device")
		}
		let exchange = RelayExchange(
			request: request, sender: sender.id, streamLifetime: streamLifetime, send: send)
		if let refusal {
			log("relay.rejected", ["device": sender.id, "detail": refusal.code])
			Thread.detachNewThread {
				exchange.respond(refusal.status, headers: [("X-WL-Request-Id", "-")], body: refusal.envelope)
			}
			return
		}
		lock.lock()
		let key = Self.key(sender.id, request.id)
		guard active[key] == nil, let handler else {
			lock.unlock()
			return
		}
		active[key] = exchange
		lock.unlock()
		exchange.onStreamStart = { [weak self] in self?.registerStream($0) }
		let thread = Thread { [weak self] in
			handler(exchange)
			exchange.close()
			self?.finished(exchange)
		}
		thread.name = "link-relay"
		thread.start()
	}

	/// `api_cancel`: only the sender of a request can cancel it.
	func cancel(id: String, sender: String) {
		lock.lock()
		let exchange = active[Self.key(sender, id)]
		lock.unlock()
		guard let exchange else { return }
		exchange.cancel(byPhone: true)
		log("relay.cancelled", ["device": sender, "detail": "id=\(id)"])
	}

	func streamCount(sender: String) -> Int {
		lock.lock()
		defer { lock.unlock() }
		return streams[sender]?.count ?? 0
	}

	var activeCount: Int {
		lock.lock()
		defer { lock.unlock() }
		return active.count
	}

	private func registerStream(_ exchange: RelayExchange) {
		lock.lock()
		var mine = streams[exchange.sender] ?? []
		mine.append(exchange)
		var evicted: [RelayExchange] = []
		while mine.count > Self.maxStreamsPerPhone { evicted.append(mine.removeFirst()) }
		streams[exchange.sender] = mine
		lock.unlock()
		for old in evicted {
			old.cancel(byPhone: false)
			log("relay.stream_evicted", ["device": old.sender, "detail": "id=\(old.request.id)"])
		}
	}

	private func finished(_ exchange: RelayExchange) {
		lock.lock()
		active[Self.key(exchange.sender, exchange.request.id)] = nil
		streams[exchange.sender]?.removeAll { $0 === exchange }
		if streams[exchange.sender]?.isEmpty == true { streams[exchange.sender] = nil }
		lock.unlock()
	}
}
