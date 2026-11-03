import Foundation
import Network

/// One request on one connection (HTTP/1.0 semantics, PROTOCOL §5.0: one request per
/// connection, `Content-Length` bodies, SSE ends when the connection closes).
///
/// Handlers run on a thread of their own and use the blocking calls below, the same model as the
/// Python daemon's `ThreadingHTTPServer`, so a slow herdr call or a 3 s broker wait never
/// stalls another request.
public final class HTTPExchange: @unchecked Sendable {
	public let method: String
	/// The request target exactly as it arrived on the request line, percent-encoding untouched.
	public let target: String
	public let path: String
	public let query: String
	public let version: String
	public let headers: [(String, String)]
	public let remoteHost: String
	/// The address of this Mac the connection arrived on; nil when the stack did not say.
	public let localHost: String?
	/// The interface the connection arrived on (`utun4`, `en0`, `lo0`); nil when unknown.
	public let localInterface: String?
	let connection: NWConnection
	private var buffered: Data
	private let lock = NSLock()
	private var failed = false
	private(set) var status = 0
	private var headersSent = false
	private var watching = false
	/// Flips when the peer closes its side (`watchForDisconnect`), or the connection fails.
	public let cancelToken = CancelToken()

	init(
		method: String, target: String, version: String, headers: [(String, String)], remoteHost: String,
		localHost: String? = nil, localInterface: String? = nil, connection: NWConnection, leftover: Data
	) {
		self.localHost = localHost
		self.localInterface = localInterface
		self.method = method
		self.target = target
		self.version = version
		self.headers = headers
		self.remoteHost = remoteHost
		self.connection = connection
		buffered = leftover
		if let mark = target.firstIndex(of: "?") {
			path = String(target[..<mark])
			query = String(target[target.index(after: mark)...])
		} else {
			path = target
			query = ""
		}
	}

	public func header(_ name: String) -> String? {
		headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
	}

	public var headerDictionary: [String: String] {
		var out: [String: String] = [:]
		for (name, value) in headers where out[name] == nil { out[name] = value }
		return out
	}

	struct ConnectionGone: Error {}
	struct ReadTimeout: Error {}

	static func receive(_ connection: NWConnection, timeout: TimeInterval) throws -> Data {
		let semaphore = DispatchSemaphore(value: 0)
		let box = ReceiveBox()
		connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
			box.data = data
			box.finished = isComplete || error != nil
			semaphore.signal()
		}
		guard semaphore.wait(timeout: .now() + timeout) == .success else { throw ReadTimeout() }
		if let data = box.data, !data.isEmpty { return data }
		throw ConnectionGone()
	}

	private final class ReceiveBox: @unchecked Sendable {
		var data: Data?
		var finished = false
	}

	/// Reads exactly `count` body bytes, each wait bounded by `timeout`.
	public func readBody(_ count: Int, timeout: TimeInterval = 30) throws -> Data {
		var body = Data()
		if !buffered.isEmpty {
			let take = min(count, buffered.count)
			body.append(buffered.prefix(take))
			buffered.removeFirst(take)
		}
		while body.count < count {
			let chunk = try Self.receive(connection, timeout: timeout)
			let take = min(count - body.count, chunk.count)
			body.append(chunk.prefix(take))
		}
		return body
	}

	/// `100 Continue` for HTTP/1.1 clients that wait for it (curl does above 1 KiB).
	func sendContinueIfExpected() {
		guard version == "HTTP/1.1", header("Expect")?.lowercased() == "100-continue" else { return }
		try? write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
	}

	static let reasons: [Int: String] = [
		100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
		404: "Not Found", 409: "Conflict", 410: "Gone", 411: "Length Required", 413: "Payload Too Large",
		422: "Unprocessable Entity", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
		500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
	]

	private func head(_ status: Int, _ headers: [(String, String)]) -> Data {
		var out = "HTTP/1.0 \(status) \(Self.reasons[status] ?? "Status")\r\n"
		out += "Server: whispera-link/\(LinkDaemon.version)\r\n"
		out += "Date: \(Self.httpDate())\r\n"
		for (name, value) in headers { out += "\(name): \(value)\r\n" }
		out += "\r\n"
		return Data(out.utf8)
	}

	static func httpDate() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "GMT")
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
		return formatter.string(from: Date())
	}

	/// Sends a complete response and closes the connection.
	public func respond(
		_ status: Int, contentType: String = "application/json", headers extra: [(String, String)] = [], body: Data
	) {
		lock.lock()
		guard !headersSent else {
			lock.unlock()
			return
		}
		headersSent = true
		self.status = status
		lock.unlock()
		var headers: [(String, String)] = [
			("Content-Type", contentType), ("Content-Length", String(body.count)), ("Cache-Control", "no-store"),
		]
		headers.append(contentsOf: extra)
		var data = head(status, headers)
		if method != "HEAD" { data.append(body) }
		let semaphore = DispatchSemaphore(value: 0)
		connection.send(
			content: data, contentContext: .finalMessage, isComplete: true,
			completion: .contentProcessed { _ in
				semaphore.signal()
			})
		_ = semaphore.wait(timeout: .now() + 30)
		connection.cancel()
	}

	/// Starts a streamed response (SSE): headers now, then `write` per frame.
	public func beginStream(_ status: Int, headers: [(String, String)]) throws {
		lock.lock()
		headersSent = true
		self.status = status
		lock.unlock()
		try write(head(status, headers))
	}

	/// Answers `101 Switching Protocols` for a WebSocket handshake and hands the connection over:
	/// the returned bytes are what the client already sent past the request head. The server
	/// leaves an upgraded connection open when the handler returns; the caller closes it.
	func upgradeToWebSocket(key: String, headers extra: [(String, String)] = []) throws -> Data {
		lock.lock()
		guard !headersSent else {
			lock.unlock()
			throw ConnectionGone()
		}
		headersSent = true
		status = 101
		lock.unlock()
		var out = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		out += "Sec-WebSocket-Accept: \(WebSocket.acceptKey(key))\r\n"
		out += "Server: whispera-link/\(LinkDaemon.version)\r\n"
		for (name, value) in extra { out += "\(name): \(value)\r\n" }
		out += "\r\n"
		try write(Data(out.utf8))
		let leftover = buffered
		buffered = Data()
		return leftover
	}

	/// Writes bytes and waits until the stack took them; throws once the peer is gone.
	public func write(_ data: Data, timeout: TimeInterval = 60) throws {
		lock.lock()
		let dead = failed
		lock.unlock()
		if dead { throw ConnectionGone() }
		let semaphore = DispatchSemaphore(value: 0)
		let box = ReceiveBox()
		connection.send(
			content: data,
			completion: .contentProcessed { error in
				box.finished = error != nil
				semaphore.signal()
			})
		let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
		if timedOut || box.finished || connection.state != .ready {
			lock.lock()
			failed = true
			lock.unlock()
			throw ConnectionGone()
		}
	}

	public var isAlive: Bool {
		lock.lock()
		defer { lock.unlock() }
		return !failed && connection.state == .ready && !cancelToken.isCancelled
	}

	/// Watches the connection once the request is read: a client sends nothing after its body
	/// (one request per connection), so the end of its stream or a failed connection means it
	/// stopped waiting, and `cancelToken` flips. Never for a WebSocket: it reads the socket itself.
	func watchForDisconnect() {
		lock.lock()
		guard !watching else {
			lock.unlock()
			return
		}
		watching = true
		lock.unlock()
		watchReceive()
	}

	private func watchReceive() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
			guard let self else { return }
			if isComplete || error != nil {
				self.cancelToken.cancel(error.map { "connection failed: \($0)" } ?? "connection closed")
				return
			}
			// Stray bytes after the body: nothing reads them; keep watching for the close.
			self.watchReceive()
		}
	}

	public func close() {
		connection.cancel()
	}
}

/// HTTP/1.0 over Network.framework (`NWListener`), with optional Bonjour advertising.
public final class HTTPServer: @unchecked Sendable {
	public struct Advertisement: Sendable {
		public var type: String
		public var txt: [String: String]
	}

	static let maxHeaderBytes = 16 * 1024
	static let headerTimeout: TimeInterval = 30

	private let host: String
	private let port: Int
	private let advertisement: Advertisement?
	private let handler: (HTTPExchange) -> Void
	/// Bonjour registration changes, for the ops log (`add(name)` / `remove(name)`).
	public var onServiceRegistration: ((String) -> Void)?
	/// Decides from the peer's address and the local address it arrived on whether a connection
	/// is served (`DirectAccessPolicy`); a refused one is closed before any byte is read. Nil
	/// admits all.
	public var admit: ((_ peer: String, _ local: String?, _ interface: String?) -> Bool)?
	/// A refused peer, for the ops log.
	public var onRefused: ((String) -> Void)?
	private let queue = DispatchQueue(label: "link.http.listener")
	private var listener: NWListener?
	public private(set) var boundPort = 0

	public init(host: String, port: Int, advertisement: Advertisement?, handler: @escaping (HTTPExchange) -> Void) {
		self.host = host
		self.port = port
		self.advertisement = advertisement
		self.handler = handler
	}

	/// TCP with Nagle off: the terminal's small frames (a keystroke's ack, then its echo a few
	/// milliseconds later) must not wait for the phone's delayed ACK of the previous one.
	static func parameters() -> NWParameters {
		let tcp = NWProtocolTCP.Options()
		tcp.noDelay = true
		let parameters = NWParameters(tls: nil, tcp: tcp)
		parameters.allowLocalEndpointReuse = true
		return parameters
	}

	/// Binds and starts listening; returns the bound port (useful with `port` 0).
	@discardableResult
	public func start() throws -> Int {
		let parameters = Self.parameters()
		let requested = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
		let listener: NWListener
		if host.isEmpty || host == "0.0.0.0" || host == "::" {
			listener = try NWListener(using: parameters, on: requested)
		} else {
			parameters.requiredLocalEndpoint = .hostPort(
				host: NWEndpoint.Host(host == "localhost" ? "127.0.0.1" : host), port: requested)
			listener = try NWListener(using: parameters)
		}
		if let advertisement {
			listener.service = NWListener.Service(
				name: nil, type: advertisement.type, domain: nil, txtRecord: NWTXTRecord(advertisement.txt))
		}
		let ready = DispatchSemaphore(value: 0)
		let failure = FailureBox()
		listener.stateUpdateHandler = { state in
			switch state {
			case .ready: ready.signal()
			case .failed(let error):
				failure.error = error
				ready.signal()
			default: break
			}
		}
		listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
		if let report = onServiceRegistration {
			listener.serviceRegistrationUpdateHandler = { change in
				switch change {
				case .add(let endpoint): report("add \(endpoint)")
				case .remove(let endpoint): report("remove \(endpoint)")
				@unknown default: report("\(change)")
				}
			}
		}
		listener.start(queue: queue)
		guard ready.wait(timeout: .now() + 10) == .success else {
			listener.cancel()
			throw NSError(
				domain: "HTTPServer", code: 1,
				userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
		}
		if let error = failure.error {
			listener.cancel()
			throw error
		}
		if let report = onServiceRegistration {
			listener.stateUpdateHandler = { state in
				if case .waiting(let error) = state { report("listener waiting: \(error)") }
				if case .failed(let error) = state { report("listener failed: \(error)") }
			}
		}
		self.listener = listener
		boundPort = Int(listener.port?.rawValue ?? UInt16(port))
		return boundPort
	}

	private final class FailureBox: @unchecked Sendable {
		var error: Error?
	}

	/// Starts or stops the Bonjour advertisement of a running listener.
	public func setAdvertisement(_ advertisement: Advertisement?) {
		queue.async { [weak self] in
			guard let listener = self?.listener else { return }
			listener.service = advertisement.map {
				NWListener.Service(name: nil, type: $0.type, domain: nil, txtRecord: NWTXTRecord($0.txt))
			}
		}
	}

	public func stop() {
		listener?.cancel()
		listener = nil
	}

	private func accept(_ connection: NWConnection) {
		let connectionQueue = DispatchQueue(label: "link.http.connection")
		connection.start(queue: connectionQueue)
		let thread = Thread { [handler, admit, onRefused] in
			let local = Self.localHost(connection)
			let interface = Self.localInterface(connection)
			if let admit {
				let peer = Self.remoteHost(connection)
				guard admit(peer, local, interface) else {
					connection.cancel()
					onRefused?(peer)
					return
				}
			}
			guard let exchange = Self.readHead(connection, localHost: local, localInterface: interface) else {
				connection.cancel()
				return
			}
			handler(exchange)
			if exchange.status == 0 { connection.cancel() }
		}
		thread.name = "link-http"
		thread.start()
	}

	/// The local address once the connection is ready (up to 2 s), before any byte is read.
	static func localHost(_ connection: NWConnection) -> String? {
		let deadline = Date().addingTimeInterval(2)
		while Date() < deadline {
			if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint {
				switch host {
				case .ipv4(let address): return "\(address)"
				case .ipv6(let address): return "\(address)"
				default: return nil
				}
			}
			switch connection.state {
			case .failed, .cancelled: return nil
			default: usleep(2_000)
			}
		}
		return nil
	}

	/// The interface the ready connection's path runs over, the one replies to the peer leave on.
	/// A peer that reached this Mac through en0 is reported on en0, unless its address routes
	/// into the tunnel, and then its handshake never completes because the replies go into
	/// WireGuard.
	static func localInterface(_ connection: NWConnection) -> String? {
		connection.currentPath?.availableInterfaces.first?.name
	}

	static func remoteHost(_ connection: NWConnection) -> String {
		if case .hostPort(let host, _) = connection.endpoint {
			switch host {
			case .ipv4(let address): return "\(address)"
			case .ipv6(let address): return "\(address)"
			case .name(let name, _): return name
			@unknown default: return "\(host)"
			}
		}
		return "-"
	}

	/// Reads up to the end of the header block and parses it; nil on a malformed or slow head.
	static func readHead(
		_ connection: NWConnection, localHost: String? = nil, localInterface: String? = nil
	) -> HTTPExchange? {
		var data = Data()
		let separator = Data("\r\n\r\n".utf8)
		let deadline = Date().addingTimeInterval(headerTimeout)
		var end: Range<Data.Index>?
		while end == nil {
			guard data.count <= maxHeaderBytes, deadline.timeIntervalSinceNow > 0,
				let chunk = try? HTTPExchange.receive(connection, timeout: deadline.timeIntervalSinceNow)
			else { return nil }
			data.append(chunk)
			end = data.range(of: separator)
		}
		guard let end, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .isoLatin1) else {
			return nil
		}
		var lines = head.components(separatedBy: "\r\n")
		let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
		guard requestLine.count == 3 else { return nil }
		var headers: [(String, String)] = []
		for line in lines where !line.isEmpty {
			guard let colon = line.firstIndex(of: ":") else { return nil }
			headers.append(
				(
					String(line[..<colon]).trimmingCharacters(in: .whitespaces),
					String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
				))
		}
		return HTTPExchange(
			method: String(requestLine[0]), target: String(requestLine[1]), version: String(requestLine[2]),
			headers: headers,
			remoteHost: remoteHost(connection), localHost: localHost, localInterface: localInterface,
			connection: connection, leftover: Data(data[end.upperBound...]))
	}
}
