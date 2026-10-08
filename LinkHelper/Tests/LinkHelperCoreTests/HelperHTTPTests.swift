import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// The helper over real HTTP on loopback: pairing, the §4.3 refusal order, `last_device`, and
/// the voice server answering from the Mac's own engine.
final class HelperHTTPTests: XCTestCase {
	var helper: TestDaemon!
	var engine: FakeEngine!

	override func setUpWithError() throws {
		engine = FakeEngine()
		helper = try TestDaemon(engine: engine)
	}

	override func tearDown() {
		helper.stop()
	}

    func testRecipeRoutesRequirePairingAndHideTemplates() async throws {
        var unsigned = URLRequest(url: helper.baseURL.appendingPathComponent("v1/recipes"))
        unsigned.httpMethod = "GET"
        let refused = try await SoftPhone.send(unsigned)
        XCTAssertEqual(refused.status, 401)
        let phone = try await helper.pairedPhone()
        let catalog = try await SoftPhone.send(try phone.signed("GET", "/v1/recipes"))
        XCTAssertEqual(catalog.status, 200)
        for recipe in catalog.json["recipes"] as? [[String: Any]] ?? [] {
            XCTAssertNil(recipe["steps"])
            XCTAssertNil(recipe["prompt"])
        }
        let run = try await SoftPhone.send(try phone.signed("POST", "/v1/recipes/nonexistent-qa-recipe/run", body: WireJSON.encode(["text": "Keep my original"])))
        XCTAssertEqual(run.status, 404)
    }

	func testPairingResponseIsSignedByTheDaemonKeyAndTheCodeIsSingleUse() async throws {
		let begin = helper.daemon.pairing.begin(ttl: 60)
		let code = (begin["code"] as! String).replacingOccurrences(of: "-", with: "")
		XCTAssertTrue((begin["qr_payload"] as! String).hasSuffix("fp=\(helper.daemon.daemonFP)"))
		let phone = SoftPhone(baseURL: helper.baseURL)
		let paired = try await phone.pair(code: code, daemonFP: helper.daemon.daemonFP)
		XCTAssertEqual(paired.status, 201)
		let signature = Data(base64Encoded: paired.headers["X-WL-Server-Signature"] as? String ?? "")!
		let daemonKey = try LinkPublicKey(x963Base64: paired.json["daemon_pubkey"] as! String)
		XCTAssertEqual(daemonKey.fingerprint, helper.daemon.daemonFP)
		XCTAssertTrue(daemonKey.isValidSignature(signature, for: LinkCrypto.pairResponseMessage(body: paired.body)))
		XCTAssertTrue(phone.sttKey.hasPrefix("wlk_"))

		let again = try await SoftPhone(baseURL: helper.baseURL).pair(code: code, daemonFP: helper.daemon.daemonFP)
		XCTAssertEqual(again.status, 403)
		XCTAssertEqual(again.errorCode, "pair_code_invalid")
	}

	func testFifthWrongCodeLocksOnlyThatAddressNotTheCode() async throws {
		let begin = helper.daemon.pairing.begin(ttl: 60)
		let code = (begin["code"] as! String).replacingOccurrences(of: "-", with: "")
		let guesser = SoftPhone(baseURL: helper.baseURL)
		let wrong = try guesser.pairingBody(
			code: "ZZZZZZZZ", daemonFP: helper.daemon.daemonFP, pairID: "pc_x", nonce: LinkCrypto.randomBytes(32))
		var codes: [String?] = []
		for _ in 0..<5 { codes.append(try await guesser.reveal(wrong).errorCode) }
		XCTAssertEqual(
			codes,
			["pair_code_invalid", "pair_code_invalid", "pair_code_invalid", "pair_code_invalid", "pair_locked"])
		XCTAssertTrue(helper.daemon.pairing.isLive, "one peer's guesses must not burn the owner's code")

		// The owner's phone, from another address, still pairs with the live code.
		let pairing = helper.daemon.pairing
		let owner = SoftPhone(baseURL: helper.baseURL)
		let nonce = LinkCrypto.randomBytes(32)
		let commitment = owner.commitment(code: code, daemonFP: helper.daemon.daemonFP, nonce: nonce)
		let (ack, _) = try pairing.handleCommit(
			WireJSON.encode(["v": 2, "commitment": commitment]), from: "192.0.2.10")
		let pairID = try XCTUnwrap(WireJSON.decodeObject(ack)?["pair_id"] as? String)
		let body = try owner.pairingBody(code: code, daemonFP: helper.daemon.daemonFP, pairID: pairID, nonce: nonce)
		let (out, _) = try pairing.handlePair(WireJSON.encode(body), from: "192.0.2.10")
		XCTAssertNotNil(WireJSON.decodeObject(out)?["device_id"] as? String)
	}

	func testSignedRequestsAreRefusedInProtocolOrder() async throws {
		let phone = try await helper.pairedPhone()
		var unsigned = URLRequest(url: helper.baseURL.appendingPathComponent("v1/devices/me"))
		unsigned.httpMethod = "GET"
		let r1 = try await SoftPhone.send(unsigned)
		XCTAssertEqual(r1.errorCode, "auth_missing")

		let skewed = try await SoftPhone.send(
			try phone.signed("GET", "/v1/devices/me", timestamp: Int64(Date().timeIntervalSince1970) + 90))
		XCTAssertEqual(skewed.errorCode, "auth_clock_skew")
		XCTAssertNotNil((skewed.json["error"] as? [String: Any])?["server_time"])

		let request = try phone.signed("GET", "/v1/devices/me")
		let first = try await SoftPhone.send(request)
		XCTAssertEqual(first.status, 200)
		XCTAssertEqual((first.json["device"] as? [String: Any])?["device_id"] as? String, phone.deviceID)
		XCTAssertNil((first.json["device"] as? [String: Any])?["stt_key_sha256"])
		let r2 = try await SoftPhone.send(request)
		XCTAssertEqual(r2.errorCode, "auth_replay")

		var tampered = try phone.signed("GET", "/v1/devices/me")
		tampered.url = URL(string: helper.baseURL.absoluteString + "/v1/approvals/pending")
		let r3 = try await SoftPhone.send(tampered)
		XCTAssertEqual(r3.errorCode, "auth_bad_signature")

		let state = helper.daemon.config.paths.lastDevice
		XCTAssertEqual(try String(contentsOfFile: state, encoding: .utf8), phone.deviceID + "\n")
		XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: state)[.posixPermissions] as? Int, 0o600)

		let r4 = try await phone.call("DELETE", "/v1/devices/me")
		XCTAssertEqual(r4.status, 200)
		let r5 = try await phone.call("GET", "/v1/devices/me")
		XCTAssertEqual(r5.errorCode, "auth_revoked")
	}

	func testHerdrMissingIsACodedErrorNotAHang() async throws {
		let phone = try await helper.pairedPhone()
		let response = try await phone.call("GET", "/v1/agents")
		XCTAssertEqual(response.status, 503)
		XCTAssertEqual(response.errorCode, "herdr_unavailable")
		let bad = try await phone.call("POST", "/v1/agents/w1%3Ap1/keys", json: ["keys": ["esc; rm"]])
		XCTAssertEqual(bad.errorCode, "bad_request")
	}

	func testVoiceServerTranscribesWithTheMacEngineOverTheSTTBearer() async throws {
		let phone = try await helper.pairedPhone()
		let wav = try TestAudio.wav(seconds: 1.5)

		var models = URLRequest(url: helper.baseURL.appendingPathComponent("v1/models"))
		models.setValue("Bearer \(phone.sttKey)", forHTTPHeaderField: "Authorization")
		let listed = try await SoftPhone.send(models)
		let ids = (listed.json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
		XCTAssertEqual(ids, ["whispera-mac"])
		XCTAssertEqual(
			(listed.json["data"] as? [[String: Any]])?.first?["task"] as? String, "automatic-speech-recognition")

		for (format, check) in [
			(
				"json",
				{ (r: SoftPhone.Response) in XCTAssertEqual(r.json["text"] as? String, "hello from the mac") }
			),
			(
				"text",
				{ (r: SoftPhone.Response) in
					XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello from the mac\n")
				}
			),
			(
				"verbose_json",
				{ (r: SoftPhone.Response) in
					XCTAssertEqual(r.json["language"] as? String, "de")
					XCTAssertEqual((r.json["duration"] as? Double) ?? 0, 1.5, accuracy: 0.01)
					XCTAssertEqual((r.json["segments"] as? [[String: Any]])?.count, 1)
				}
			),
		] {
			let (body, contentType) = TestAudio.multipart(
				wav, fields: ["model": "whisper-1", "language": "de", "response_format": format])
			var request = URLRequest(url: helper.baseURL.appendingPathComponent("v1/audio/transcriptions"))
			request.httpMethod = "POST"
			request.httpBody = body
			request.setValue(contentType, forHTTPHeaderField: "Content-Type")
			request.setValue("Bearer \(phone.sttKey)", forHTTPHeaderField: "Authorization")
			let response = try await SoftPhone.send(request)
			XCTAssertEqual(response.status, 200, format)
			check(response)
		}
		XCTAssertEqual(Double(engine.lastSampleCount), 1.5 * 16_000, accuracy: 160)
		XCTAssertEqual(engine.lastLanguage, "de")

		let (srt, contentType) = TestAudio.multipart(wav, fields: ["model": "whisper-1", "response_format": "srt"])
		var unsupported = URLRequest(url: helper.baseURL.appendingPathComponent("v1/audio/transcriptions"))
		unsupported.httpMethod = "POST"
		unsupported.httpBody = srt
		unsupported.setValue(contentType, forHTTPHeaderField: "Content-Type")
		unsupported.setValue("Bearer \(phone.sttKey)", forHTTPHeaderField: "Authorization")
		let r6 = try await SoftPhone.send(unsupported)
		XCTAssertEqual(r6.errorCode, "bad_request")

		var wrongKey = URLRequest(url: helper.baseURL.appendingPathComponent("v1/models"))
		wrongKey.setValue("Bearer wlk_not_a_key", forHTTPHeaderField: "Authorization")
		let r7 = try await SoftPhone.send(wrongKey)
		XCTAssertEqual(r7.errorCode, "auth_unknown_device")
	}

	func testVoiceServerWithoutAModelSaysSo() async throws {
		engine.models = []
		let phone = try await helper.pairedPhone()
		let response = try await phone.call("GET", "/v1/models")
		XCTAssertEqual(response.status, 200)
		let model = (response.json["data"] as? [[String: Any]])?.first
		XCTAssertEqual(model?["ready"] as? Bool, false)
		XCTAssertEqual(model?["message"] as? String, SpeechService.noModelReady)
		let health = try await SoftPhone.send(URLRequest(url: helper.baseURL.appendingPathComponent("v1/health")))
		XCTAssertEqual(health.json["stt"] as? String, "unconfigured")
	}
}
