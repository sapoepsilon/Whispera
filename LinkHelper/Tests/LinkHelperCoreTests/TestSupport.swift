import AVFoundation
import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// A phone made of software keys, talking to an in-process helper over real HTTP.
final class SoftPhone {
	let baseURL: URL
	let linkKey: SoftwareSigningKey
	let approveKey: SoftwareSigningKey
	var deviceID = ""
	var sttKey = ""

	init(
		baseURL: URL, linkKey: SoftwareSigningKey = SoftwareSigningKey(),
		approveKey: SoftwareSigningKey = SoftwareSigningKey()
	) {
		self.baseURL = baseURL
		self.linkKey = linkKey
		self.approveKey = approveKey
	}

	struct Response {
		var status: Int
		var body: Data
		var headers: [AnyHashable: Any]
		var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
		var errorCode: String? { (json["error"] as? [String: Any])?["code"] as? String }
	}

	static func send(_ request: URLRequest) async throws -> Response {
		let (data, response) = try await URLSession.shared.data(for: request)
		let http = response as! HTTPURLResponse
		return Response(status: http.statusCode, body: data, headers: http.allHeaderFields)
	}

	static func post(_ url: URL, _ body: [String: Any]) async throws -> Response {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		return try await send(request)
	}

	/// What a pairing v2 run sent, so tests can replay or tamper with it.
	struct PairingRun {
		var commit: Response
		var reveal: [String: Any]
		var response: Response?
	}

	func pairingBody(code: String, daemonFP: String, pairID: String, nonce: Data) throws -> [String: Any] {
		let proof = try linkKey.sign(
			LinkCrypto.pairProofMessage(code: code, daemonFP: daemonFP, approveX963: approveKey.publicKey.x963))
		let approveProof = try approveKey.sign(LinkCrypto.pairApproveMessage(code: code, daemonFP: daemonFP))
		return [
			"v": 2, "pair_id": pairID, "nonce": nonce.base64EncodedString(), "code": code, "name": "Test iPhone",
			"link_pubkey": linkKey.publicKey.x963Base64, "approve_pubkey": approveKey.publicKey.x963Base64,
			"proof": proof.base64EncodedString(), "approve_proof": approveProof.base64EncodedString(),
			"apns": NSNull(),
		]
	}

	func commitment(code: String, daemonFP: String, nonce: Data) -> String {
		LinkCrypto.pairCommitment(
			code: code, daemonFP: daemonFP, linkX963: linkKey.publicKey.x963, approveX963: approveKey.publicKey.x963,
			nonce: nonce)
	}

	/// Pairing v2: commit, check the signed acknowledgement, then reveal (unless `reveal` is
	/// false, for tests that capture the reveal and send something else).
	func pairV2(code: String, daemonFP: String, reveal: Bool = true) async throws -> PairingRun {
		let nonce = LinkCrypto.randomBytes(32)
		let commitment = commitment(code: code, daemonFP: daemonFP, nonce: nonce)
		let commit = try await Self.post(
			baseURL.appendingPathComponent("v1/pair/commit"), ["v": 2, "commitment": commitment])
		let pairID = commit.json["pair_id"] as? String ?? ""
		if commit.status == 201 {
			let key = try LinkPublicKey(x963Base64: commit.json["daemon_pubkey"] as? String ?? "")
			let signature = Data(base64Encoded: commit.headers["X-WL-Server-Signature"] as? String ?? "") ?? Data()
			XCTAssertEqual(key.fingerprint, daemonFP)
			XCTAssertTrue(key.isValidSignature(signature, for: LinkCrypto.pairCommitAckMessage(body: commit.body)))
			XCTAssertEqual(commit.json["commitment"] as? String, commitment)
		}
		let body = try pairingBody(code: code, daemonFP: daemonFP, pairID: pairID, nonce: nonce)
		var run = PairingRun(commit: commit, reveal: body, response: nil)
		if reveal, commit.status == 201 {
			let response = try await Self.post(baseURL.appendingPathComponent("v1/pair"), body)
			deviceID = response.json["device_id"] as? String ?? ""
			sttKey = response.json["stt_key"] as? String ?? ""
			run.response = response
		}
		return run
	}

	/// Pairing v2 end to end; answers the reveal's response (or the commit's on a refusal).
	func pair(code: String, daemonFP: String) async throws -> Response {
		let run = try await pairV2(code: code, daemonFP: daemonFP)
		return run.response ?? run.commit
	}

	/// A wrong-code reveal: no commitment first (a guesser).
	func reveal(_ body: [String: Any]) async throws -> Response {
		try await Self.post(baseURL.appendingPathComponent("v1/pair"), body)
	}

	func signed(
		_ method: String, _ target: String, body: Data = Data(), timestamp: Int64? = nil,
		nonce: String = LinkCrypto.makeNonce()
	) throws -> URLRequest {
		var request = URLRequest(url: URL(string: baseURL.absoluteString + target)!)
		request.httpMethod = method
		if !body.isEmpty || method == "POST" || method == "PUT" { request.httpBody = body }
		let headers = try SignedHeaders.sign(
			key: linkKey, deviceID: deviceID, method: method, target: target, body: body,
			timestamp: timestamp ?? Int64(Date().timeIntervalSince1970), nonce: nonce)
		headers.apply(to: &request)
		return request
	}

	func call(_ method: String, _ target: String, json: [String: Any]? = nil) async throws -> Response {
		let body = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
		return try await Self.send(try signed(method, target, body: body))
	}
}

/// A helper on 127.0.0.1:0 with its state in a temp directory.
final class TestDaemon {
	let directory: URL
	let daemon: LinkDaemon
	let port: Int

	init(
		engine: LocalSpeechEngine? = nil, upstream: String = "", accountTransport: LinkTransport? = nil,
		herdrSocket: String? = nil,
		configure: (inout HelperConfig) -> Void = { _ in }
	) throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"wlh-\(UUID().uuidString.prefix(8))")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var config = HelperConfig(
			paths: .init(
				config: directory.appendingPathComponent("config.json").path,
				stateDir: directory.appendingPathComponent("state").path,
				log: directory.appendingPathComponent("helper.log").path))
		config.listenHost = "127.0.0.1"
		config.port = 0
		config.bonjour = false
		config.herdrSocket = herdrSocket ?? directory.appendingPathComponent("no-herdr.sock").path
		// Never the real herdr CLI: no remote machines unless a test brings the fake one.
		config.herdrCLI = ""
		config.sttUpstreamBaseURL = upstream
		configure(&config)
		daemon = try LinkDaemon(
			config: config, engine: engine, accountTransport: accountTransport ?? URLSessionLinkTransport())
		port = try daemon.start()
	}

	var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

	func pairedPhone() async throws -> SoftPhone {
		let begin = daemon.pairing.begin(ttl: 60)
		let code = (begin["code"] as! String).replacingOccurrences(of: "-", with: "")
		let phone = SoftPhone(baseURL: baseURL)
		let response = try await phone.pair(code: code, daemonFP: daemon.daemonFP)
		XCTAssertEqual(response.status, 201)
		return phone
	}

	func stop() {
		daemon.stop()
		if ProcessInfo.processInfo.environment["WLH_KEEP"] == nil {
			try? FileManager.default.removeItem(at: directory)
		}
	}
}

/// Records what it was asked and answers a fixed transcript.
final class FakeEngine: LocalSpeechEngine, @unchecked Sendable {
	var models = ["openai_whisper-small"]
	private(set) var lastSampleCount = 0
	private(set) var lastLanguage: String?

	func modelIDs() -> [String] { models }

	func transcribe(samples: [Float], language: String?, prompt: String?, temperature: Float?) async throws
		-> LocalTranscript
	{
		lastSampleCount = samples.count
		lastLanguage = language
		return LocalTranscript(
			text: "hello from the mac", language: language ?? "en",
			segments: [.init(start: 0, end: 1.5, text: "hello from the mac")])
	}
}

enum TestAudio {
	/// A 16-bit PCM WAV of a sine tone.
	static func wav(seconds: Double, sampleRate: Double = 44_100) throws -> Data {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
		defer { try? FileManager.default.removeItem(at: url) }
		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsFloatKey: false,
		]
		do {
			// The header's length is written when the file object goes away.
			let file = try AVAudioFile(forWriting: url, settings: settings)
			let frames = AVAudioFrameCount(seconds * sampleRate)
			let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
			buffer.frameLength = frames
			for channel in 0..<Int(file.processingFormat.channelCount) {
				for frame in 0..<Int(frames) {
					buffer.floatChannelData![channel][frame] = Float(
						sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.3)
				}
			}
			try file.write(from: buffer)
		}
		return try Data(contentsOf: url)
	}

	static func multipart(_ audio: Data, fields: [String: String], filename: String = "clip.wav") -> (Data, String) {
		let boundary = "wlb\(UUID().uuidString.prefix(8))"
		var body = Data()
		for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
			body.append(
				Data(
					"--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
						.utf8))
		}
		body.append(
			Data(
				"--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n"
					.utf8))
		body.append(audio)
		body.append(Data("\r\n--\(boundary)--\r\n".utf8))
		return (body, "multipart/form-data; boundary=\(boundary)")
	}
}
