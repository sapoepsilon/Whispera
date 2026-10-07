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

	func pair(code: String, daemonFP: String) async throws -> Response {
		let proof = try linkKey.sign(
			LinkCrypto.pairProofMessage(code: code, daemonFP: daemonFP, approveX963: approveKey.publicKey.x963))
		let approveProof = try approveKey.sign(LinkCrypto.pairApproveMessage(code: code, daemonFP: daemonFP))
		let body: [String: Any] = [
			"v": 1, "code": code, "name": "Test iPhone", "link_pubkey": linkKey.publicKey.x963Base64,
			"approve_pubkey": approveKey.publicKey.x963Base64, "proof": proof.base64EncodedString(),
			"approve_proof": approveProof.base64EncodedString(), "apns": NSNull(),
		]
		var request = URLRequest(url: baseURL.appendingPathComponent("v1/pair"))
		request.httpMethod = "POST"
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		let response = try await Self.send(request)
		deviceID = response.json["device_id"] as? String ?? ""
		sttKey = response.json["stt_key"] as? String ?? ""
		return response
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
