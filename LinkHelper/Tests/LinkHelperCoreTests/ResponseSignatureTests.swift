import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// Direct-path responses and SSE events signed with the daemon key
/// (docs/LINK_RESPONSE_SIGNATURES.md).
final class ResponseSignatureTests: XCTestCase {
	private let key = SoftwareSigningKey()
	private var signer: ResponseSigner { ResponseSigner(key: key, now: { 1_700_000_000 }) }
	private let nonce = LinkCrypto.makeNonce()

	private func dictionary(_ pairs: [(String, String)]) -> [String: String] {
		Dictionary(pairs, uniquingKeysWith: { first, _ in first })
	}

	// MARK: Complete responses

	func testASignedResponseVerifiesAndAnyTamperingFails() {
		let body = Data(#"{"ok":true}"#.utf8)
		let headers = dictionary(signer.headers(nonce: nonce, method: "GET", target: "/v1/agents?x=1", status: 200, body: body))
		XCTAssertEqual(headers[ResponseSigner.timestampHeader], "1700000000")
		let verify = { (nonce: String, method: String, target: String, status: Int, body: Data?, headers: [String: String]) in
			ResponseSigner.verifyResponse(
				publicKey: self.key.publicKey, nonce: nonce, method: method, target: target, status: status, body: body,
				headers: headers)
		}
		XCTAssertEqual(try verify(nonce, "get", "/v1/agents?x=1", 200, body, headers).get(), 1_700_000_000)
		XCTAssertEqual(verify(nonce, "GET", "/v1/agents?x=1", 200, Data(#"{"ok":false}"#.utf8), headers), .failure(.badSignature))
		XCTAssertEqual(verify(nonce, "GET", "/v1/agents?x=1", 201, body, headers), .failure(.badSignature))
		XCTAssertEqual(verify(LinkCrypto.makeNonce(), "GET", "/v1/agents?x=1", 200, body, headers), .failure(.badSignature))
		XCTAssertEqual(verify("", "GET", "/v1/agents?x=1", 200, body, headers), .failure(.badSignature))
		XCTAssertEqual(verify(nonce, "POST", "/v1/agents?x=1", 200, body, headers), .failure(.badSignature))
		XCTAssertEqual(verify(nonce, "GET", "/v1/agents?x=2", 200, body, headers), .failure(.badSignature))
		XCTAssertEqual(verify(nonce, "GET", "/v1/agents?x=1", 200, nil, headers), .failure(.badSignature))
		var moved = headers
		moved[ResponseSigner.timestampHeader] = "1700000001"
		XCTAssertEqual(verify(nonce, "GET", "/v1/agents?x=1", 200, body, moved), .failure(.badSignature))
		var missing = headers
		missing[ResponseSigner.signatureHeader] = nil
		XCTAssertEqual(verify(nonce, "GET", "/v1/agents?x=1", 200, body, missing), .failure(.missing))
		XCTAssertEqual(
			ResponseSigner.verifyResponse(
				publicKey: SoftwareSigningKey().publicKey, nonce: nonce, method: "GET", target: "/v1/agents?x=1",
				status: 200, body: body, headers: headers),
			.failure(.badSignature))
		XCTAssertEqual(
			ResponseSigner.verifyResponse(
				publicKey: key.publicKey, nonce: nonce, method: "GET", target: "/v1/agents?x=1", status: 200, body: body,
				headers: headers, now: 1_700_000_000 + 600, maxAge: 120),
			.failure(.stale))
	}

	func testTheCanonicalMessageLayout() {
		let message = ResponseSigner.responseMessage(
			timestamp: 42, nonce: nonce, method: "post", target: "/v1/a b\n", status: 404, bodyHash: "h")
		XCTAssertEqual(String(decoding: message, as: UTF8.self), "WL1-RESP\n42\n\(nonce)\nPOST\n/v1/a%20b%0A\n404\nh")
		let event = ResponseSigner.eventMessage(timestamp: 42, nonce: "", seq: 3, event: Data())
		XCTAssertEqual(
			String(decoding: event, as: UTF8.self), "WL1-RESP-EVENT\n42\n\n3\n" + LinkCrypto.emptyBodySHA256)
	}

	func testOnlyAWellFormedNonceIsBound() {
		XCTAssertEqual(ResponseSigner.boundNonce(nonce), nonce)
		XCTAssertEqual(ResponseSigner.boundNonce(nil), "")
		XCTAssertEqual(ResponseSigner.boundNonce("short"), "")
		XCTAssertEqual(ResponseSigner.boundNonce(String(nonce.dropLast()) + "\n"), "")
	}

	// MARK: SSE events

	/// Splits a signed stream into its event blocks (without the blank line that ends each).
	private func blocks(_ data: Data) -> [Data] {
		var out: [Data] = []
		var rest = data
		while let end = rest.range(of: Data("\n\n".utf8)) {
			out.append(Data(rest[rest.startIndex..<(end.lowerBound + 1)]))
			rest = Data(rest[end.upperBound...])
		}
		return out
	}

	func testEachEventIsSignedInSequenceAndPingsPassUnsigned() throws {
		let events = SSEEventSigner(signer: signer, nonce: nonce)
		var out = events.process(Data("event: hello\ndata: {\"v\":1}\n\n: ping\n\n".utf8))
		// Half an event waits for the rest.
		XCTAssertEqual(events.process(Data("event: frame\nid: 7\n".utf8)), Data())
		out += events.process(Data("data: AAA=\n\nevent: frame\ndata: BBB=\n\n".utf8))
		let parts = blocks(out)
		XCTAssertEqual(parts.count, 4)
		XCTAssertEqual(parts[1], Data(": ping\n".utf8))
		let signed = [parts[0], parts[2], parts[3]]
		for (index, block) in signed.enumerated() {
			let original = try ResponseSigner.verifyEvent(
				publicKey: key.publicKey, nonce: nonce, expectedSeq: UInt64(index + 1), block: block
			).get()
			XCTAssertFalse(String(decoding: original, as: UTF8.self).contains("wl-sig"))
		}
		XCTAssertEqual(
			String(decoding: try ResponseSigner.verifyEvent(publicKey: key.publicKey, nonce: nonce, expectedSeq: 2, block: parts[2]).get(), as: UTF8.self),
			"event: frame\nid: 7\ndata: AAA=\n")
		// An old client's parser sees the same frames: the extra field is ignored.
		var parser = LinkSSEParser()
		let frames = parser.consume(String(decoding: out, as: UTF8.self))
		XCTAssertEqual(frames.map(\.data), [#"{"v":1}"#, "AAA=", "BBB="])
	}

	func testReorderedDroppedOrRewrittenEventsFail() {
		let events = SSEEventSigner(signer: signer, nonce: nonce)
		let parts = blocks(events.process(Data("data: one\n\ndata: two\n\n".utf8)))
		XCTAssertEqual(parts.count, 2)
		// Dropping the first, or swapping the two, shows up as a sequence gap.
		XCTAssertEqual(
			ResponseSigner.verifyEvent(publicKey: key.publicKey, nonce: nonce, expectedSeq: 1, block: parts[1]),
			.failure(.badSignature))
		let rewritten = Data(String(decoding: parts[0], as: UTF8.self).replacingOccurrences(of: "one", with: "own").utf8)
		XCTAssertEqual(
			ResponseSigner.verifyEvent(publicKey: key.publicKey, nonce: nonce, expectedSeq: 1, block: rewritten),
			.failure(.badSignature))
		XCTAssertEqual(
			ResponseSigner.verifyEvent(
				publicKey: key.publicKey, nonce: LinkCrypto.makeNonce(), expectedSeq: 1, block: parts[0]),
			.failure(.badSignature))
		XCTAssertEqual(
			ResponseSigner.verifyEvent(publicKey: key.publicKey, nonce: nonce, expectedSeq: 1, block: Data("data: one\n".utf8)),
			.failure(.missing))
	}

	// MARK: Over HTTP

	private func header(_ response: SoftPhone.Response) -> [String: String] {
		var out: [String: String] = [:]
		for (name, value) in response.headers {
			if let name = name as? String, let value = value as? String { out[name] = value }
		}
		return out
	}

	private func verify(
		_ helper: TestDaemon, _ response: SoftPhone.Response, nonce: String, method: String, target: String,
		file: StaticString = #filePath, line: UInt = #line
	) throws {
		let key = try LinkPublicKey(x963Base64: helper.daemon.daemonPubkeyB64)
		let result = ResponseSigner.verifyResponse(
			publicKey: key, nonce: nonce, method: method, target: target, status: response.status, body: response.body,
			headers: header(response), now: Int64(Date().timeIntervalSince1970), maxAge: 60)
		XCTAssertNoThrow(try result.get(), "\(method) \(target) \(response.status)", file: file, line: line)
	}

	func testEveryDirectResponseIsSignedIncludingRefusals() async throws {
		let helper = try TestDaemon()
		defer { helper.stop() }
		// Unsigned: still signed, bound to no nonce.
		let health = try await SoftPhone.send(URLRequest(url: helper.baseURL.appendingPathComponent("v1/health")))
		XCTAssertEqual(health.status, 200)
		try verify(helper, health, nonce: "", method: "GET", target: "/v1/health")
		// An unsigned request that brings a nonce gets it bound.
		var bound = URLRequest(url: helper.baseURL.appendingPathComponent("v1/health"))
		let healthNonce = LinkCrypto.makeNonce()
		bound.setValue(healthNonce, forHTTPHeaderField: SignedHeaders.nonceHeader)
		try verify(helper, try await SoftPhone.send(bound), nonce: healthNonce, method: "GET", target: "/v1/health")

		// 403: an account device the owner has not confirmed yet.
		let pinned = SoftPhone(baseURL: helper.baseURL)
		pinned.deviceID = LinkCrypto.newDeviceID()
		_ = try helper.daemon.devices.pinAccountDevice(
			deviceID: pinned.deviceID, name: "Pinned", link: pinned.linkKey.publicKey,
			approve: pinned.approveKey.publicKey, kem: SoftwareSigningKey().publicKey)
		var nonce = LinkCrypto.makeNonce()
		let unconfirmed = try await SoftPhone.send(try pinned.signed("GET", "/v1/recipes", nonce: nonce))
		XCTAssertEqual(unconfirmed.status, 403)
		try verify(helper, unconfirmed, nonce: nonce, method: "GET", target: "/v1/recipes")

		let phone = try await helper.pairedPhone()
		nonce = LinkCrypto.makeNonce()
		let me = try await SoftPhone.send(try phone.signed("GET", "/v1/devices/me", nonce: nonce))
		XCTAssertEqual(me.status, 200)
		try verify(helper, me, nonce: nonce, method: "GET", target: "/v1/devices/me")
		XCTAssertEqual((me.json["device"] as? [String: Any])?["device_id"] as? String, phone.deviceID)

		nonce = LinkCrypto.makeNonce()
		let missing = try await SoftPhone.send(try phone.signed("GET", "/v1/nothing-here", nonce: nonce))
		XCTAssertEqual(missing.status, 404)
		try verify(helper, missing, nonce: nonce, method: "GET", target: "/v1/nothing-here")

		// A bad signature (401) is still signed, bound to the nonce it carried.
		nonce = LinkCrypto.makeNonce()
		var forged = try phone.signed("GET", "/v1/devices/me", nonce: nonce)
		forged.setValue(Data(repeating: 1, count: 70).base64EncodedString(), forHTTPHeaderField: SignedHeaders.signatureHeader)
		let refused = try await SoftPhone.send(forged)
		XCTAssertEqual(refused.status, 401)
		try verify(helper, refused, nonce: nonce, method: "GET", target: "/v1/devices/me")
	}

	func testTheEventStreamSignsItsHeadAndEveryEvent() throws {
		let helper = try TestDaemon()
		defer { helper.stop() }
		let phone = try runBlocking { try await helper.pairedPhone() }
		let nonce = LinkCrypto.makeNonce()
		let request = try phone.signed("GET", "/v1/events", nonce: nonce)
		let fd = try Self.openSocket(port: helper.port)
		defer { Darwin.close(fd) }
		var head = "GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\n"
		for (name, value) in request.allHTTPHeaderFields ?? [:] { head += "\(name): \(value)\r\n" }
		head += "\r\n"
		_ = Data(head.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

		var received = try Self.read(fd, until: { $0.range(of: Data("wl-sig: 1 ".utf8)) != nil })
		_ = helper.daemon.hub.publish("agents.changed", ["why": "test"])
		let first = received
		received += try Self.read(fd) { data in
			let all = first + data
			guard let mark = all.range(of: Data("wl-sig: 2 ".utf8)) else { return false }
			return all[mark.upperBound...].range(of: Data("\n\n".utf8)) != nil
		}

		let key = try LinkPublicKey(x963Base64: helper.daemon.daemonPubkeyB64)
		let split = try XCTUnwrap(received.range(of: Data("\r\n\r\n".utf8)))
		var headers: [String: String] = [:]
		for line in String(decoding: received[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
			let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			if parts.count == 2 { headers[parts[0]] = parts[1] }
		}
		XCTAssertNoThrow(
			try ResponseSigner.verifyResponse(
				publicKey: key, nonce: nonce, method: "GET", target: "/v1/events", status: 200, body: nil, headers: headers
			).get())
		let parts = blocks(Data(received[split.upperBound...])).filter { !$0.starts(with: Data(":".utf8)) }
		XCTAssertGreaterThanOrEqual(parts.count, 2)
		let hello = try ResponseSigner.verifyEvent(publicKey: key, nonce: nonce, expectedSeq: 1, block: parts[0]).get()
		XCTAssertTrue(String(decoding: hello, as: UTF8.self).hasPrefix("event: hello\n"))
		let changed = try ResponseSigner.verifyEvent(publicKey: key, nonce: nonce, expectedSeq: 2, block: parts[1]).get()
		XCTAssertTrue(String(decoding: changed, as: UTF8.self).contains("event: agents.changed\n"))
	}

	// MARK: Plumbing

	private func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
		let semaphore = DispatchSemaphore(value: 0)
		let box = ResultBox<T>()
		Task {
			do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
			semaphore.signal()
		}
		semaphore.wait()
		return try box.result!.get()
	}

	private final class ResultBox<T>: @unchecked Sendable {
		var result: Result<T, Error>?
	}

	static func openSocket(port: Int) throws -> Int32 {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		var timeout = timeval(tv_sec: 5, tv_usec: 0)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = in_port_t(UInt16(port).bigEndian)
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
		return fd
	}

	/// Reads until `done` holds for what arrived so far (or 5 s without a byte).
	static func read(_ fd: Int32, until done: (Data) -> Bool) throws -> Data {
		var out = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while !done(out) {
			let count = recv(fd, &buffer, buffer.count, 0)
			guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
			out.append(contentsOf: buffer[0..<count])
		}
		return out
	}
}
