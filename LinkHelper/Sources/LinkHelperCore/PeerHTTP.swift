import Foundation
import Network

/// The one HTTP client a probe uses to reach another helper on the tailnet. It is a plain TCP
/// connection (Network.framework) carrying one hand-written HTTP/1.1 GET with
/// `Connection: close`, because inside the signed helper bundle App Transport Security refuses
/// cleartext URLSession loads to an IP before they connect (NSURLErrorDomain -1022), and the
/// answer is a signed proof that needs no transport security of its own.
///
/// Only a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48) as a literal: no names, no
/// proxies, no redirects (any status but 200 is nothing), no chunked or encoded bodies, a byte
/// cap read as the body streams and one deadline for the whole exchange. Anything else is nil.
final class PeerHTTP: @unchecked Sendable {
	static let maxBytes = 256 * 1024
	static let deadline: TimeInterval = 5
	/// Status line plus headers; the helper's own answers are a few hundred bytes.
	static let maxHeadBytes = 16 * 1024

	private let allowsHost: @Sendable (String) -> Bool
	private let lock = NSLock()
	private var inFlight: [ObjectIdentifier: Exchange] = [:]

	/// `allowsHost` decides which literal addresses may be dialled; only tests widen it (to loopback).
	init(allowsHost: @escaping @Sendable (String) -> Bool = { PeerHTTP.isTailnetAddress($0) }) {
		self.allowsHost = allowsHost
	}

	/// Cancels whatever is in flight; later `get`s still work.
	func invalidate() {
		let running: [Exchange] = lock.withLock {
			let out = Array(inFlight.values)
			inFlight = [:]
			return out
		}
		for exchange in running { exchange.cancel() }
	}

	/// The body of a 200 answer to `url`, or nil (not `http`, not an allowed address, any other
	/// status, over `maxBytes`, past `deadline`, malformed, any error).
	func get(_ url: URL, maxBytes: Int = PeerHTTP.maxBytes, deadline: TimeInterval = PeerHTTP.deadline) async -> Data? {
		guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "http",
			parts.user == nil, parts.password == nil, parts.fragment == nil, let host = parts.host
		else { return nil }
		var target = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
		if let query = parts.percentEncodedQuery { target += "?" + query }
		return await get(host: host, port: parts.port ?? 80, target: target, maxBytes: maxBytes, deadline: deadline)
	}

	/// `GET target` on `host:port`, where `host` is a literal address (IPv6 with or without brackets).
	func get(
		host rawHost: String, port: Int, target: String, maxBytes: Int = PeerHTTP.maxBytes,
		deadline: TimeInterval = PeerHTTP.deadline
	) async -> Data? {
		let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
		guard allowsHost(host), let address = Self.literal(host), let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)),
			(1...65535).contains(port), Self.isSafeTarget(target), maxBytes >= 0, deadline > 0
		else { return nil }
		let hostHeader = (address.isIPv6 ? "[\(host)]" : host) + ":\(port)"
		let request = Data(
			"GET \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\nAccept: application/json\r\nConnection: close\r\nUser-Agent: whispera-link-helper\r\n\r\n"
				.utf8)
		let exchange = Exchange(
			endpoint: .hostPort(host: address.host, port: nwPort), request: request, maxBytes: maxBytes, deadline: deadline)
		let key = ObjectIdentifier(exchange)
		lock.withLock { inFlight[key] = exchange }
		defer { lock.withLock { _ = inFlight.removeValue(forKey: key) } }
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in exchange.start(continuation) }
		} onCancel: {
			exchange.cancel()
		}
	}

	// MARK: Addresses

	/// A Tailscale address, as a literal: 100.64.0.0/10 or fd7a:115c:a1e0::/48.
	static func isTailnetAddress(_ host: String) -> Bool {
		guard let address = literal(host) else { return false }
		let bytes = [UInt8](address.raw)
		if address.isIPv6 {
			return bytes.count == 16 && bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c
				&& bytes[4] == 0xa1 && bytes[5] == 0xe0
		}
		return bytes.count == 4 && bytes[0] == 100 && bytes[1] & 0xc0 == 64
	}

	struct Literal {
		let host: NWEndpoint.Host
		let raw: Data
		let isIPv6: Bool
	}

	/// A strict dotted quad or an IPv6 literal without a zone; never a name (nothing is resolved).
	static func literal(_ host: String) -> Literal? {
		if host.contains(":") {
			guard !host.contains("%"), let v6 = IPv6Address(host) else { return nil }
			return Literal(host: .ipv6(v6), raw: v6.rawValue, isIPv6: true)
		}
		let octets = host.split(separator: ".", omittingEmptySubsequences: false)
		guard octets.count == 4,
			octets.allSatisfy({
				(1...3).contains($0.count) && $0.allSatisfy({ $0.isASCII && $0.isNumber }) && Int($0)! <= 255
					&& ($0.count == 1 || $0.first != "0")
			}),
			let v4 = IPv4Address(host)
		else { return nil }
		return Literal(host: .ipv4(v4), raw: v4.rawValue, isIPv6: false)
	}

	/// An origin-form target of visible ASCII only: nothing that could end the request line early.
	static func isSafeTarget(_ target: String) -> Bool {
		target.hasPrefix("/") && target.utf8.count <= 8192 && target.utf8.allSatisfy { (0x21...0x7e).contains($0) }
	}

	// MARK: Response parsing

	struct Head: Equatable {
		let status: Int
		let contentLength: Int?
	}

	enum HeadResult: Equatable {
		case needMore
		case refused
		case head(Head, bodyStart: Int)
	}

	/// The status line and headers at the start of `buffer`. Refused: not HTTP/1.0 or 1.1, a bad
	/// status line or header, `Transfer-Encoding` (chunked or not), a `Content-Encoding` other
	/// than identity, an unparseable or conflicting `Content-Length`, or a head over `maxHeadBytes`.
	static func parseHead(_ buffer: Data) -> HeadResult {
		let separator = Data("\r\n\r\n".utf8)
		guard let end = buffer.range(of: separator) else {
			return buffer.count > maxHeadBytes ? .refused : .needMore
		}
		let headCount = end.lowerBound - buffer.startIndex
		guard headCount <= maxHeadBytes else { return .refused }
		let headBytes = buffer[buffer.startIndex..<end.lowerBound]
		guard headBytes.allSatisfy({ $0 == 0x09 || $0 == 0x0d || $0 == 0x0a || (0x20...0x7e).contains($0) }),
			let head = String(data: headBytes, encoding: .ascii)
		else { return .refused }
		let lines = head.components(separatedBy: "\r\n")
		guard let statusLine = lines.first, !lines.dropFirst().contains(where: { $0.contains("\r") || $0.contains("\n") })
		else { return .refused }
		let fields = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
		guard fields.count >= 2, fields[0] == "HTTP/1.1" || fields[0] == "HTTP/1.0", fields[1].count == 3,
			fields[1].allSatisfy({ $0.isASCII && $0.isNumber }), let status = Int(fields[1]), (100...599).contains(status)
		else { return .refused }
		var contentLength: Int?
		for line in lines.dropFirst() {
			guard let colon = line.firstIndex(of: ":") else { return .refused }
			let name = line[..<colon]
			guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) })
			else { return .refused }
			let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
			switch name.lowercased() {
			case "transfer-encoding":
				return .refused
			case "content-encoding":
				guard value.lowercased() == "identity" else { return .refused }
			case "content-length":
				guard (1...12).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(value),
					contentLength == nil || contentLength == length
				else { return .refused }
				contentLength = length
			default:
				break
			}
		}
		return .head(Head(status: status, contentLength: contentLength), bodyStart: end.upperBound - buffer.startIndex)
	}

	// MARK: One exchange

	private final class Exchange: @unchecked Sendable {
		private let connection: NWConnection
		private let queue = DispatchQueue(label: "whispera.link.peer-http")
		private let request: Data
		private let maxBytes: Int
		private let deadline: TimeInterval
		private let lock = NSLock()
		private var continuation: CheckedContinuation<Data?, Never>?
		private var done = false
		// Touched only on `queue`.
		private var buffer = Data()
		private var head: Head?
		private var bodyStart = 0

		init(endpoint: NWEndpoint, request: Data, maxBytes: Int, deadline: TimeInterval) {
			let tcp = NWProtocolTCP.Options()
			tcp.noDelay = true
			tcp.connectionTimeout = max(1, Int(deadline.rounded(.up)))
			let parameters = NWParameters(tls: nil, tcp: tcp)
			parameters.preferNoProxies = true
			connection = NWConnection(to: endpoint, using: parameters)
			self.request = request
			self.maxBytes = maxBytes
			self.deadline = deadline
		}

		func start(_ continuation: CheckedContinuation<Data?, Never>) {
			let cancelledEarly: Bool = lock.withLock {
				if done { return true }
				self.continuation = continuation
				return false
			}
			if cancelledEarly {
				continuation.resume(returning: nil)
				return
			}
			queue.async { [self] in
				guard !lock.withLock({ done }) else { return }
				connection.stateUpdateHandler = { [weak self] state in
					guard let self else { return }
					switch state {
					case .ready: self.send()
					// No waiting for connectivity: a Mac that is not there now is nothing this round.
					case .waiting, .failed, .cancelled: self.finish(nil)
					default: break
					}
				}
				queue.asyncAfter(deadline: .now() + deadline) { [weak self] in self?.finish(nil) }
				connection.start(queue: queue)
			}
		}

		func cancel() { finish(nil) }

		private func finish(_ result: Data?) {
			let (first, waiting): (Bool, CheckedContinuation<Data?, Never>?) = lock.withLock {
				if done { return (false, nil) }
				done = true
				let out = continuation
				continuation = nil
				return (true, out)
			}
			guard first else { return }
			let connection = self.connection
			queue.async {
				connection.stateUpdateHandler = nil
				if connection.state != .setup { connection.cancel() }
			}
			waiting?.resume(returning: result)
		}

		private func send() {
			connection.send(
				content: request,
				completion: .contentProcessed { [weak self] error in
					guard let self else { return }
					if error != nil { return self.finish(nil) }
					self.receive()
				})
		}

		private func receive() {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
				guard let self else { return }
				if let data, !data.isEmpty { self.buffer.append(data) }
				if self.consume(isComplete: isComplete) { return }
				if error != nil || isComplete { return self.finish(nil) }
				self.receive()
			}
		}

		/// Whether the exchange is over (finished either way) after what has arrived so far.
		private func consume(isComplete: Bool) -> Bool {
			if head == nil {
				switch PeerHTTP.parseHead(buffer) {
				case .needMore:
					return false
				case .refused:
					finish(nil)
					return true
				case .head(let parsed, let start):
					guard parsed.status == 200, (parsed.contentLength ?? 0) <= maxBytes else {
						finish(nil)
						return true
					}
					head = parsed
					bodyStart = start
				}
			}
			guard let head else { return false }
			let received = buffer.count - bodyStart
			if let length = head.contentLength {
				guard received >= length else { return false }
				let from = buffer.startIndex + bodyStart
				finish(Data(buffer[from..<(from + length)]))
				return true
			}
			if received > maxBytes {
				finish(nil)
				return true
			}
			guard isComplete else { return false }
			finish(Data(buffer[(buffer.startIndex + bodyStart)...]))
			return true
		}
	}
}
