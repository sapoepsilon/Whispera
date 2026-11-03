import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// An account phone that talks to the helper's LinkAPI over the relay: it sends `api_request`s
/// and collects `api_response` frames per request id.
final class RelayPhone {
	let phone: AccountPhone
	let macID: String
	private var frames: [String: [RelayAPIResponse]] = [:]

	init(_ phone: AccountPhone, macID: String) {
		self.phone = phone
		self.macID = macID
	}

	/// A WL1-signed request (or an unsigned one), as the phone's relay transport builds it.
	func request(
		_ method: String, _ target: String, json: [String: Any]? = nil, stream: Bool = false, signed: Bool = true,
		signer: (key: SoftwareSigningKey, deviceID: String)? = nil
	) throws -> RelayAPIRequest {
		let body = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
		var headers: [String: String] = [:]
		if json != nil { headers["Content-Type"] = "application/json" }
		if stream { headers["Accept"] = "text/event-stream" }
		if signed {
			let who = signer ?? (phone.linkKey, phone.deviceID)
			let signedHeaders = try SignedHeaders.sign(
				key: who.key, deviceID: who.deviceID, method: method, target: target, body: body,
				timestamp: Int64(Date().timeIntervalSince1970), nonce: LinkCrypto.makeNonce())
			for (name, value) in signedHeaders.headerPairs { headers[name] = value }
		}
		return RelayAPIRequest(method: method, target: target, headers: headers, body: body, stream: stream)
	}

	func send(_ request: RelayAPIRequest) async throws {
		try await phone.send(.apiRequest(request), toDevice: macID)
	}

	func cancel(_ id: String) async throws {
		try await phone.send(.apiCancel(id: id), toDevice: macID)
	}

	/// Reads the phone's queue once and files the frames by request id.
	func drain() async throws {
		for message in try await phone.receive() {
			if case .apiResponse(let frame) = message { frames[frame.id, default: []].append(frame) }
		}
	}

	func frames(_ id: String) -> [RelayAPIResponse] { frames[id] ?? [] }

	/// Waits (pumping the Mac's mailbox with `pump`) until `id` has a final frame.
	func response(
		_ id: String, timeout: TimeInterval = 10, pump: () async throws -> Void
	) async throws -> (status: Int, headers: [String: String], body: Data) {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			try await pump()
			try await drain()
			if frames(id).contains(where: \.final) { return try RelayAPIResponseAssembler.assemble(frames(id)) }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		throw RelayAPIError.incomplete
	}

	/// Waits until `predicate` holds for `id`'s frames.
	func waitFrames(
		_ id: String, timeout: TimeInterval = 10, pump: () async throws -> Void,
		until predicate: ([RelayAPIResponse]) -> Bool
	) async throws -> [RelayAPIResponse] {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			try await pump()
			try await drain()
			if predicate(frames(id)) { return frames(id) }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		XCTFail("frames for \(id) never matched; got \(frames(id).count)")
		return frames(id)
	}
}

/// The LinkAPI over the account relay (step 12): the same handler, the same checks, plus the
/// relay's own rules (sender = signer, no pairing or speech, SSE as frames, stream caps).
final class RelayIngressTests: XCTestCase {
	var backend: FakeAccountBackend!
	var helper: TestDaemon!

	override func setUpWithError() throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.macName = "Test Mac"
		}
	}

	override func tearDown() {
		helper.stop()
	}

	private var account: AccountLink { helper.daemon.account }

	private func pump() async throws { _ = try await account.syncNow() }

	/// A phone of the account, pinned by the Mac, with its offer read.
	private func pinnedPhone(name: String = "Test iPhone", confirmed: Bool = true) async throws -> (
		RelayPhone, AccountPhone
	) {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice", name: name)
		let status = try await account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		let macID = try XCTUnwrap(status["device_id"] as? String)
		_ = try await account.syncNow()
		if confirmed {
			_ = try await account.confirmApprove(phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
		}
		_ = try await phone.receive()
		return (RelayPhone(phone, macID: macID), phone)
	}

	private func json(_ body: Data) -> [String: Any] {
		(try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
	}

	private func errorCode(_ body: Data) -> String? {
		(json(body)["error"] as? [String: Any])?["code"] as? String
	}

	func testSignedRequestOverTheRelayIsServedLikeDirect() async throws {
		let (relay, phone) = try await pinnedPhone()
		let request = try relay.request("GET", "/v1/devices/me")
		let started = Date()
		try await relay.send(request)
		let response = try await relay.response(request.id, pump: pump)
		XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a relayed request is served promptly")
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(response.headers["Content-Type"], "application/json")
		XCTAssertNotNil(response.headers["X-WL-Request-Id"])
		XCTAssertNil(response.headers["Content-Length"], "only whitelisted headers travel")
		XCTAssertEqual((json(response.body)["device"] as? [String: Any])?["device_id"] as? String, phone.deviceID)
		XCTAssertEqual(helper.daemon.lastDevice.current, phone.deviceID)
		let log = try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8)
		XCTAssertTrue(log.contains("route=devices.me status=200"))
		XCTAssertTrue(log.contains("via=relay"))

		// The same replay cache as direct: the same signed bytes again are a replay.
		let replay = RelayAPIRequest(
			method: request.method, target: request.target, headers: request.headers, body: request.body)
		try await relay.send(replay)
		let replayed = try await relay.response(replay.id, pump: pump)
		XCTAssertEqual(replayed.status, 401)
		XCTAssertEqual(errorCode(replayed.body), "auth_replay")
	}

	func testTheSignerMustBeTheRelaySender() async throws {
		let (relayA, _) = try await pinnedPhone(name: "A")
		let phoneB = AccountPhone(backend: backend)
		try await phoneB.register(bearer: "tok-alice", name: "B")
		_ = try await account.syncNow()
		XCTAssertNotNil(helper.daemon.devices.get(phoneB.deviceID))

		// A forwards a request B signed: the envelope says A, the headers say B.
		let forwarded = try relayA.request("GET", "/v1/devices/me", signer: (phoneB.linkKey, phoneB.deviceID))
		try await relayA.send(forwarded)
		let response = try await relayA.response(forwarded.id, pump: pump)
		XCTAssertEqual(response.status, 401)
		XCTAssertEqual(errorCode(response.body), "auth_unknown_device")
		XCTAssertNil(helper.daemon.lastDevice.current)

		let unsigned = try relayA.request("GET", "/v1/devices/me", signed: false)
		try await relayA.send(unsigned)
		let refused = try await relayA.response(unsigned.id, pump: pump)
		XCTAssertEqual(errorCode(refused.body), "auth_unknown_device")
	}

	func testPairingIsNotAvailableOverTheRelay() async throws {
		let (relay, _) = try await pinnedPhone()
		for (method, target) in [("POST", "/v1/pair"), ("POST", "/v1/pair/commit")] {
			let request = try relay.request(method, target, json: method == "POST" ? ["v": 1] : nil)
			try await relay.send(request)
			let response = try await relay.response(request.id, pump: pump)
			XCTAssertEqual(response.status, 404, target)
			XCTAssertEqual(errorCode(response.body), "not_found", target)
			XCTAssertEqual(
				(json(response.body)["error"] as? [String: Any])?["message"] as? String, "not available over the relay")
		}
	}

	func testTheTerminalWebSocketIsUnavailableOverTheRelay() async throws {
		let (relay, _) = try await pinnedPhone()
		let request = try relay.request("GET", "/v1/agents/w1:p1/terminal/ws?cols=80&rows=24")
		try await relay.send(request)
		let response = try await relay.response(request.id, pump: pump)
		XCTAssertEqual(response.status, 400)
		XCTAssertEqual(errorCode(response.body), "websocket_unavailable")
	}

	func testUnsignedHealthIsAllowedOverTheRelay() async throws {
		let (relay, _) = try await pinnedPhone()
		let request = try relay.request("GET", "/v1/health", signed: false)
		try await relay.send(request)
		let response = try await relay.response(request.id, pump: pump)
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(json(response.body)["ok"] as? Bool, true)
		XCTAssertEqual(json(response.body)["daemon_fp"] as? String, helper.daemon.daemonFP)
	}

	func testAnUnconfirmedPhoneOverTheRelayGetsOnlyItsOwnRecord() async throws {
		let (relay, phone) = try await pinnedPhone(confirmed: false)
		let me = try relay.request("GET", "/v1/devices/me")
		try await relay.send(me)
		let answered = try await relay.response(me.id, pump: pump)
		XCTAssertEqual(answered.status, 200)
		XCTAssertEqual((json(answered.body)["device"] as? [String: Any])?["approve_confirmed"] as? Bool, false)
		for (method, target, body) in [
			("GET", "/v1/agents", nil), ("POST", "/v1/agents/w1-p1/prompt", ["text": "rm -rf ~"]),
			("GET", "/v1/approvals/pending", nil), ("GET", "/v1/events", nil),
		] as [(String, String, [String: Any]?)] {
			let request = try relay.request(method, target, json: body)
			try await relay.send(request)
			let response = try await relay.response(request.id, pump: pump)
			XCTAssertEqual(response.status, 403, target)
			XCTAssertEqual(errorCode(response.body), "device_unconfirmed", target)
		}
		XCTAssertNil(helper.daemon.lastDevice.current, "an unconfirmed phone never becomes the push target")
		XCTAssertFalse(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)
	}

	func testOnlyPinnedPhonesAreServed() async throws {
		let (relay, phone) = try await pinnedPhone()
		helper.daemon.devices.revoke(phone.deviceID)
		let request = try relay.request("GET", "/v1/devices/me")
		try await relay.send(request)
		let response = try await relay.response(request.id, pump: pump)
		XCTAssertEqual(response.status, 401)
		XCTAssertEqual(errorCode(response.body), "auth_revoked")
	}

	func testEventsStreamOverTheRelayUntilTheCancel() async throws {
		let (relay, phone) = try await pinnedPhone()
		let request = try relay.request("GET", "/v1/events", stream: true)
		try await relay.send(request)
		let opened = try await relay.waitFrames(request.id, pump: pump) { frames in
			frames.contains { String(decoding: $0.body, as: UTF8.self).contains("event: hello") }
		}
		XCTAssertEqual(opened.first?.part, 0)
		XCTAssertEqual(opened.first?.status, 200)
		XCTAssertEqual(opened.first?.headers?["Content-Type"], "text/event-stream")
		XCTAssertFalse(opened.contains(where: \.final))
		XCTAssertEqual(helper.daemon.relayIngress.streamCount(sender: phone.deviceID), 1)
		XCTAssertNil(helper.daemon.lastDevice.current, "events is background traffic")

		helper.daemon.hub.publish("agents.changed", [:])
		_ = try await relay.waitFrames(request.id, pump: pump) { frames in
			frames.contains { String(decoding: $0.body, as: UTF8.self).contains("event: agents.changed") }
		}

		try await relay.cancel(request.id)
		let deadline = Date().addingTimeInterval(5)
		while helper.daemon.relayIngress.streamCount(sender: phone.deviceID) > 0, Date() < deadline {
			try await pump()
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		XCTAssertEqual(helper.daemon.relayIngress.streamCount(sender: phone.deviceID), 0)
		XCTAssertEqual(helper.daemon.hub.streamCount(deviceID: phone.deviceID), 0)
		try await relay.drain()
		XCTAssertFalse(relay.frames(request.id).contains(where: \.final), "a cancelled stream gets no final frame")
	}

	/// A whole answer the relay can't carry (more than the phone's relay mailbox) is a clear
	/// 413 instead of frames that stop halfway; one that fits is sent whole.
	func testAnAnswerTooLargeForTheRelayIsRefusedWithAReason() async throws {
		let (_, phone) = try await pinnedPhone()
		let sender = try TrustedDevice(verifying: try XCTUnwrap(backend.device(phone.deviceID)))
		let ingress = RelayIngress(devices: helper.daemon.devices)
		ingress.setHandler { exchange in
			let size = exchange.path == "/v1/big" ? RelayExchange.maxBody + 1 : RelayExchange.maxBody
			exchange.respond(200, contentType: "image/png", headers: [], body: Data(count: size))
		}
		let sent = FrameLog()
		let big = RelayAPIRequest(method: "GET", target: "/v1/big")
		let fits = RelayAPIRequest(method: "GET", target: "/v1/fits")
		ingress.accept(big, sender: sender) { messages in sent.append(messages) }
		ingress.accept(fits, sender: sender) { messages in sent.append(messages) }
		let deadline = Date().addingTimeInterval(10)
		while ingress.activeCount > 0, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }

		let refused = try RelayAPIResponseAssembler.assemble(sent.frames(big.id))
		XCTAssertEqual(refused.status, 413)
		XCTAssertEqual(errorCode(refused.body), "relay_too_large")
		XCTAssertTrue(((json(refused.body)["error"] as? [String: Any])?["message"] as? String)?.contains("same Wi-Fi") == true)
		let whole = try RelayAPIResponseAssembler.assemble(sent.frames(fits.id))
		XCTAssertEqual(whole.status, 200)
		XCTAssertEqual(whole.body.count, RelayExchange.maxBody)
	}

	func testStreamsPerPhoneAreCappedAndEndAfterTheirLifetime() async throws {
		let (_, phone) = try await pinnedPhone()
		let sender = try TrustedDevice(verifying: try XCTUnwrap(backend.device(phone.deviceID)))
		let ingress = RelayIngress(devices: helper.daemon.devices, streamLifetime: 1.5)
		ingress.setHandler { exchange in
			try? exchange.beginStream(200, headers: [("Content-Type", "text/event-stream")])
			while exchange.isAlive {
				try? exchange.write(Data(": ping\n\n".utf8))
				Thread.sleep(forTimeInterval: 0.05)
			}
		}
		let sent = FrameLog()
		var ids: [String] = []
		for index in 0..<5 {
			let request = RelayAPIRequest(method: "GET", target: "/v1/events", stream: true)
			ids.append(request.id)
			ingress.accept(request, sender: sender) { messages in sent.append(messages) }
			// Start order decides which stream is the oldest.
			let deadline = Date().addingTimeInterval(2)
			while ingress.streamCount(sender: phone.deviceID) < min(index + 1, 4), Date() < deadline {
				try await Task.sleep(nanoseconds: 20_000_000)
			}
		}
		try await Task.sleep(nanoseconds: 300_000_000)
		XCTAssertEqual(ingress.streamCount(sender: phone.deviceID), RelayIngress.maxStreamsPerPhone)
		XCTAssertTrue(sent.frames(ids[0]).last?.final ?? false, "the oldest stream was ended")
		XCTAssertFalse(sent.frames(ids[4]).contains(where: \.final))

		let deadline = Date().addingTimeInterval(5)
		while ingress.streamCount(sender: phone.deviceID) > 0, Date() < deadline {
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		XCTAssertEqual(ingress.streamCount(sender: phone.deviceID), 0, "every stream ends after its lifetime")
		for id in ids { XCTAssertEqual(sent.frames(id).filter(\.final).count, 1, id) }
	}

	/// Relayed requests fit one 64 KiB envelope, so dictation goes as a chunked file upload and
	/// then a small JSON request names it; the Mac transcribes it and deletes it.
	func testDictationOverTheRelayUploadsTheAudioThenTranscribesItById() async throws {
		let (relay, phone) = try await pinnedPhone()
		let health = try relay.request("GET", "/v1/health", signed: true)
		try await relay.send(health)
		let healthBody = try await relay.response(health.id, pump: pump).body
		XCTAssertTrue((json(healthBody)["capabilities"] as? [String] ?? []).contains("audio_by_file"))

		let audio = try TestAudio.wav(seconds: 1)
		XCTAssertGreaterThan(audio.count, 64 * 1024, "too large for one relayed request")
		let fileID = UUID().uuidString.lowercased()
		var offset = 0
		while offset < audio.count {
			let chunk = audio.subdata(in: offset..<min(offset + 24 * 1024, audio.count))
			let part = try relay.request("POST", "/v1/files/\(fileID)", json: [
				"name": "dictation.wav", "total_bytes": audio.count, "offset": offset, "data": chunk.base64EncodedString(),
			])
			try await relay.send(part)
			let answer = try await relay.response(part.id, pump: pump)
			XCTAssertEqual(answer.status, 200, String(decoding: answer.body, as: UTF8.self))
			offset += chunk.count
		}
		let folder = helper.directory.appendingPathComponent("state/submissions/\(phone.deviceID)/files/\(fileID)")
		XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

		let call = try relay.request("POST", "/v1/audio/transcriptions/file", json: ["file_id": fileID, "language": "en"])
		try await relay.send(call)
		let response = try await relay.response(call.id, pump: pump)
		XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
		XCTAssertEqual(json(response.body)["text"] as? String, "hello from the mac")
		XCTAssertEqual(json(response.body)["language"] as? String, "en")
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the audio is deleted once transcribed")

		let again = try relay.request("POST", "/v1/audio/transcriptions/file", json: ["file_id": fileID])
		try await relay.send(again)
		let gone = try await relay.response(again.id, pump: pump)
		XCTAssertEqual(gone.status, 404)
		XCTAssertEqual(errorCode(gone.body), "file_not_found")
	}

	/// Signed speech works over the relay (the engine check, short clips); the bearer can't
	/// name the relay sender, so it is refused there.
	func testSignedSpeechRoutesAreServedOverTheRelay() async throws {
		let (relay, _) = try await pinnedPhone()
		let models = try relay.request("GET", "/v1/models")
		try await relay.send(models)
		let listed = try await relay.response(models.id, pump: pump)
		XCTAssertEqual(listed.status, 200, String(decoding: listed.body, as: UTF8.self))
		XCTAssertEqual(((json(listed.body)["data"] as? [[String: Any]])?.first)?["id"] as? String, "whispera-mac")

		let unsigned = try relay.request("GET", "/v1/models", signed: false)
		try await relay.send(unsigned)
		let refused = try await relay.response(unsigned.id, pump: pump)
		XCTAssertEqual(refused.status, 401)
	}
}

/// Frames a test ingress sent, by request id.
final class FrameLog: @unchecked Sendable {
	private let lock = NSLock()
	private var byID: [String: [RelayAPIResponse]] = [:]

	func append(_ messages: [LinkMessage]) {
		lock.lock()
		for message in messages {
			if case .apiResponse(let frame) = message { byID[frame.id, default: []].append(frame) }
		}
		lock.unlock()
	}

	func frames(_ id: String) -> [RelayAPIResponse] {
		lock.lock()
		defer { lock.unlock() }
		return byID[id] ?? []
	}
}
