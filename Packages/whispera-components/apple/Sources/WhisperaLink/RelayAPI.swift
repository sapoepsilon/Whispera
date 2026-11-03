import Foundation

// The LinkAPI over the E2E relay: when the phone cannot reach the Mac's LinkAPI
// directly it sends the *same WL1-signed HTTP request* as an `api_request`
// `LinkMessage` (sealed in a WLE1 `SealedEnvelope`) to the Mac's account device id;
// the Mac runs it through the same handler and seals the response back as one or
// more `api_response` frames. The backend only ever sees ciphertext.
//
// ```
// {"type":"api_request","v":1,"id":"rq_<32 hex>","method":"GET","target":"/v1/agents?x=1",
//  "headers":{"X-WL-Device":"dev_…",…},"body":"<std base64>","stream":false}
// {"type":"api_response","v":1,"id":"rq_…","part":0,"status":200,
//  "headers":{"Content-Type":"application/json"},"body":"<b64 chunk>","final":true}
// {"type":"api_cancel","v":1,"id":"rq_…"}
// ```
//
// Part 0 carries status and headers (and the first body chunk); later parts carry
// only `body`; the last frame has `final: true`. Body chunks are at most
// `RelayAPI.maxChunk` raw bytes so a sealed frame stays under the relay's 64 KiB
// ciphertext cap.

public enum RelayAPI {
	/// Raw body bytes per `api_response` frame.
	public static let maxChunk = 32 * 1024
	/// `ttl_s` for every `api_*` frame.
	public static let ttl: UInt32 = 120
	/// A relayed SSE stream with no frame for this long is dead (same as the direct watchdog).
	public static let streamIdleTimeout: TimeInterval = 40
	/// The scheme of the placeholder base URL a relay-only `LinkClient` is built on:
	/// `wl-relay://<mac account device id>`. The host is not signed, so any base works.
	public static let placeholderScheme = "wl-relay"

	/// Request headers carried over the relay, canonical spelling. Everything else is dropped.
	public static let requestHeaders = [
		"X-WL-Device", "X-WL-Timestamp", "X-WL-Nonce", "X-WL-Signature", "Content-Type", "Accept", "Last-Event-ID",
	]
	/// Response headers carried over the relay, canonical spelling.
	public static let responseHeaders = ["Content-Type", "X-WL-Request-Id", "X-WL-Server-Signature", "Retry-After"]

	/// `wl-relay://<macDeviceID>` — a base URL for a `LinkClient` that only talks over the relay.
	public static func placeholderBaseURL(macDeviceID: String) -> URL {
		URL(string: "\(placeholderScheme)://\(macDeviceID)")!
	}

	/// `rq_` + 32 lowercase hex.
	public static func newRequestID() -> String {
		"rq_" + LinkCrypto.hex(LinkCrypto.randomBytes(16))
	}

	public static func isValidRequestID(_ id: String) -> Bool {
		let bytes = Array(id.utf8)
		guard bytes.count == 35, id.hasPrefix("rq_") else { return false }
		return bytes.dropFirst(3).allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
	}

	/// Keeps only the `allowed` names (matched case-insensitively) and writes them in
	/// their canonical spelling. When two spellings of one name are present the
	/// canonical one wins, then the lexicographically smallest, so the result is stable.
	public static func filterHeaders(_ headers: [String: String], allowed: [String]) -> [String: String] {
		var canonical: [String: String] = [:]
		for name in allowed { canonical[name.lowercased()] = name }
		var out: [String: String] = [:]
		for name in headers.keys.sorted() {
			guard let value = headers[name], let canon = canonical[name.lowercased()] else { continue }
			if out[canon] == nil || name == canon { out[canon] = value }
		}
		return out
	}
}

/// `api_request`: one LinkAPI call, phone → Mac.
public struct RelayAPIRequest: Codable, Equatable, Sendable {
	/// `rq_<32 hex>`; every response frame carries it.
	public var id: String
	public var method: String
	/// Path + query exactly as signed (`LinkCrypto.requestTarget(for:)`).
	public var target: String
	/// Whitelisted (`RelayAPI.requestHeaders`), canonical spelling.
	public var headers: [String: String]
	public var body: Data
	/// SSE: the Mac answers with a head frame, one frame per write, and a final frame.
	public var stream: Bool

	public init(
		id: String = RelayAPI.newRequestID(), method: String, target: String, headers: [String: String] = [:],
		body: Data = Data(), stream: Bool = false
	) {
		self.id = id
		self.method = method
		self.target = target
		self.headers = RelayAPI.filterHeaders(headers, allowed: RelayAPI.requestHeaders)
		self.body = body
		self.stream = stream
	}

	/// Serialises an (already WL1-signed) request. The host is dropped: only the
	/// target is signed and only the target travels.
	public init(_ request: URLRequest, id: String = RelayAPI.newRequestID(), stream: Bool = false) throws {
		guard let url = request.url else { throw LinkMessageError.malformed("request has no URL") }
		self.init(
			id: id, method: (request.httpMethod ?? "GET").uppercased(), target: LinkCrypto.requestTarget(for: url),
			headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Data(), stream: stream)
	}

	/// The `X-WL-Device` header: on the Mac it must equal the relay sender's id.
	public var deviceID: String? { headers["X-WL-Device"] }

	/// The `X-WL-Device` header names `senderID` — the Mac's first ingress check.
	public func isSigned(by senderID: String) -> Bool { deviceID == senderID }

	/// Path without the query, still percent-encoded.
	public var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]) }

	/// The raw query (after `?`), percent-encoded, or nil.
	public var query: String? {
		guard let index = target.firstIndex(of: "?") else { return nil }
		return String(target[target.index(after: index)...])
	}

	/// A `URLRequest` against `baseURL` + `target` — handy for a Mac that wants to run
	/// the relayed call through code written for `URLRequest`s.
	public func urlRequest(baseURL: URL) -> URLRequest? {
		var base = baseURL.absoluteString
		while base.hasSuffix("/") { base.removeLast() }
		guard let url = URL(string: base + target) else { return nil }
		var request = URLRequest(url: url)
		request.httpMethod = method
		for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
		if !body.isEmpty { request.httpBody = body }
		return request
	}

	enum CodingKeys: String, CodingKey { case id, method, target, headers, body, stream }

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		method = try c.decode(String.self, forKey: .method)
		target = try c.decode(String.self, forKey: .target)
		headers = RelayAPI.filterHeaders(
			try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:], allowed: RelayAPI.requestHeaders)
		body = try Self.decodeBody(c.decodeIfPresent(String.self, forKey: .body), codingPath: c.codingPath)
		stream = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
		guard RelayAPI.isValidRequestID(id) else { throw LinkMessageError.malformed("api_request id") }
		guard !method.isEmpty, method.utf8.allSatisfy({ (0x41...0x5a).contains($0) }) else {
			throw LinkMessageError.malformed("api_request method")
		}
		guard target.hasPrefix("/"), !target.contains(where: { $0.isWhitespace }) else {
			throw LinkMessageError.malformed("api_request target")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(id, forKey: .id)
		try c.encode(method, forKey: .method)
		try c.encode(target, forKey: .target)
		try c.encode(headers, forKey: .headers)
		try c.encode(body.base64EncodedString(), forKey: .body)
		try c.encode(stream, forKey: .stream)
	}

	static func decodeBody(_ string: String?, codingPath: [CodingKey]) throws -> Data {
		guard let string, !string.isEmpty else { return Data() }
		guard let data = Data(base64Encoded: string) else { throw LinkMessageError.malformed("body is not base64") }
		return data
	}
}

/// `api_response`: one frame of a LinkAPI response, Mac → phone.
public struct RelayAPIResponse: Codable, Equatable, Sendable {
	public var id: String
	/// 0, 1, 2, … in send order.
	public var part: Int
	/// Part 0 only.
	public var status: Int?
	/// Part 0 only; whitelisted (`RelayAPI.responseHeaders`), canonical spelling.
	public var headers: [String: String]?
	public var body: Data
	public var final: Bool

	public init(id: String, part: Int, status: Int? = nil, headers: [String: String]? = nil, body: Data = Data(), final: Bool) {
		self.id = id
		self.part = part
		self.status = status
		self.headers = headers.map { RelayAPI.filterHeaders($0, allowed: RelayAPI.responseHeaders) }
		self.body = body
		self.final = final
	}

	/// A whole (non-stream) response as frames: part 0 with status, headers and the
	/// first chunk, then one frame per `chunkSize` bytes; the last one is `final`.
	/// An empty body is a single final frame.
	public static func frames(
		id: String, status: Int, headers: [String: String] = [:], body: Data, chunkSize: Int = RelayAPI.maxChunk
	) -> [RelayAPIResponse] {
		var writer = RelayAPIStreamWriter(id: id, chunkSize: chunkSize)
		return writer.head(status: status, headers: headers, body: body, final: true)
	}

	enum CodingKeys: String, CodingKey { case id, part, status, headers, body, final }

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		part = try c.decode(Int.self, forKey: .part)
		status = try c.decodeIfPresent(Int.self, forKey: .status)
		headers = try c.decodeIfPresent([String: String].self, forKey: .headers).map {
			RelayAPI.filterHeaders($0, allowed: RelayAPI.responseHeaders)
		}
		body = try RelayAPIRequest.decodeBody(c.decodeIfPresent(String.self, forKey: .body), codingPath: c.codingPath)
		final = try c.decodeIfPresent(Bool.self, forKey: .final) ?? false
		guard RelayAPI.isValidRequestID(id) else { throw LinkMessageError.malformed("api_response id") }
		guard part >= 0 else { throw LinkMessageError.malformed("api_response part") }
		if part == 0 {
			guard let status, (100...599).contains(status) else { throw LinkMessageError.malformed("api_response status") }
		}
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(id, forKey: .id)
		try c.encode(part, forKey: .part)
		try c.encodeIfPresent(status, forKey: .status)
		try c.encodeIfPresent(headers, forKey: .headers)
		try c.encode(body.base64EncodedString(), forKey: .body)
		try c.encode(final, forKey: .final)
	}
}

/// Builds the `api_response` frames for one request in order — the Mac's side.
/// For a whole response use `head(…, final: true)` (or `RelayAPIResponse.frames`);
/// for SSE send `head`, then `write` per server write, then `finish`.
public struct RelayAPIStreamWriter: Sendable {
	public let id: String
	public let chunkSize: Int
	public private(set) var nextPart = 0
	public private(set) var isFinished = false

	public init(id: String, chunkSize: Int = RelayAPI.maxChunk) {
		self.id = id
		self.chunkSize = max(1, chunkSize)
	}

	/// Part 0 (status + headers + the first chunk of `body`) and, when `body` is
	/// longer than a chunk, the frames for the rest. `final` marks the last one.
	public mutating func head(
		status: Int, headers: [String: String] = [:], body: Data = Data(), final: Bool = false
	) -> [RelayAPIResponse] {
		precondition(nextPart == 0, "head must be the first frame")
		let chunks = Self.split(body, chunkSize)
		var frames: [RelayAPIResponse] = []
		for (index, chunk) in chunks.enumerated() {
			let last = index == chunks.count - 1
			frames.append(
				RelayAPIResponse(
					id: id, part: nextPart, status: index == 0 ? status : nil, headers: index == 0 ? headers : nil, body: chunk,
					final: final && last))
			nextPart += 1
		}
		if final { isFinished = true }
		return frames
	}

	/// One server write, split into chunk-sized frames. Empty data yields nothing.
	public mutating func write(_ data: Data) -> [RelayAPIResponse] {
		precondition(nextPart > 0 && !isFinished, "write after head and before finish")
		guard !data.isEmpty else { return [] }
		return Self.split(data, chunkSize).map { chunk in
			defer { nextPart += 1 }
			return RelayAPIResponse(id: id, part: nextPart, body: chunk, final: false)
		}
	}

	/// The final, empty frame.
	public mutating func finish() -> RelayAPIResponse {
		precondition(nextPart > 0 && !isFinished, "finish after head, once")
		isFinished = true
		defer { nextPart += 1 }
		return RelayAPIResponse(id: id, part: nextPart, final: true)
	}

	static func split(_ data: Data, _ size: Int) -> [Data] {
		guard !data.isEmpty else { return [Data()] }
		var out: [Data] = []
		var start = data.startIndex
		while start < data.endIndex {
			let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
			out.append(Data(data[start..<end]))
			start = end
		}
		return out
	}
}

public enum RelayAPIError: Error, Equatable, Sendable {
	/// Part 0 came without a status, or a frame belongs to another request.
	case badFrame(String)
	/// Too many frames arrived out of order.
	case reorderBufferFull
	/// The frames stopped before a `final` one.
	case incomplete
	/// The mailbox stopped while a request was waiting.
	case mailboxStopped
}

/// Puts `api_response` frames back in order — the phone's side. Duplicates and
/// frames after the final one are dropped; frames that arrive early are held until
/// the gap fills.
public struct RelayAPIResponseAssembler: Sendable {
	public let id: String
	public private(set) var status: Int?
	public private(set) var headers: [String: String] = [:]
	public private(set) var isComplete = false
	/// Everything delivered so far, in order — what `data(for:)` returns.
	public private(set) var body = Data()
	public let collectsBody: Bool
	public static let maxPending = 4096

	private var nextPart = 0
	private var pending: [Int: RelayAPIResponse] = [:]

	public init(id: String, collectsBody: Bool = true) {
		self.id = id
		self.collectsBody = collectsBody
	}

	/// Takes one frame and returns the body chunks that are now in order (possibly
	/// none, possibly several). `status`/`headers` are set once part 0 is in.
	public mutating func accept(_ frame: RelayAPIResponse) throws -> [Data] {
		guard frame.id == id else { throw RelayAPIError.badFrame("id") }
		guard !isComplete, frame.part >= nextPart, pending[frame.part] == nil else { return [] }
		pending[frame.part] = frame
		guard pending.count <= Self.maxPending else { throw RelayAPIError.reorderBufferFull }
		var out: [Data] = []
		while let next = pending.removeValue(forKey: nextPart) {
			if nextPart == 0 {
				guard let status = next.status else { throw RelayAPIError.badFrame("part 0 without status") }
				self.status = status
				headers = next.headers ?? [:]
			}
			nextPart += 1
			if !next.body.isEmpty {
				out.append(next.body)
				if collectsBody { body.append(next.body) }
			}
			if next.final {
				isComplete = true
				pending.removeAll()
				break
			}
		}
		return out
	}

	/// Status, headers and body of a complete set of frames in any order.
	public static func assemble(_ frames: [RelayAPIResponse]) throws -> (status: Int, headers: [String: String], body: Data) {
		guard let first = frames.first else { throw RelayAPIError.incomplete }
		var assembler = RelayAPIResponseAssembler(id: first.id)
		for frame in frames { _ = try assembler.accept(frame) }
		guard assembler.isComplete, let status = assembler.status else { throw RelayAPIError.incomplete }
		return (status, assembler.headers, assembler.body)
	}
}

/// Helpers for the Mac side of the relayed LinkAPI. The Mac's HTTP handling stays
/// in the Mac; this only turns frames into request parts and responses into frames.
public enum RelayAPIServerSupport {
	/// The first ingress check: the relay sender must be the device that signed.
	public static func checkSender(_ request: RelayAPIRequest, senderID: String) -> Bool {
		request.isSigned(by: senderID)
	}

	/// A whole response as `api_response` messages, ready for `RelayClient.send(_:to:ttl:)`.
	public static func responseMessages(
		to request: RelayAPIRequest, status: Int, headers: [String: String] = [:], body: Data
	) -> [LinkMessage] {
		RelayAPIResponse.frames(id: request.id, status: status, headers: headers, body: body).map(LinkMessage.apiResponse)
	}

	/// `{"error":{…}}` with `status`, for refusals before the handler runs.
	public static func errorMessages(to request: RelayAPIRequest, _ code: ErrorCode, message: String) -> [LinkMessage] {
		responseMessages(
			to: request, status: code.httpStatus, headers: ["Content-Type": "application/json"],
			body: ErrorEnvelope(code, message: message).encoded())
	}
}

extension RelayClient {
	/// Sends frames in order, each sealed to `recipient`, with the `api_*` TTL.
	public func send(_ messages: [LinkMessage], to recipient: TrustedDevice, ttl: UInt32 = RelayAPI.ttl) async throws {
		for message in messages { try await send(message, to: recipient, ttl: ttl) }
	}
}
