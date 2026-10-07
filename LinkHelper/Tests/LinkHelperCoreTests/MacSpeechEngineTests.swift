import Foundation
import XCTest

@testable import LinkHelperCore

/// The Mac voice server serves whatever engine is selected in Whispera on the Mac: the phone's
/// `model` never matters, a remote engine gets the Mac's model and key, and the key never
/// reaches the phone.
final class MacSpeechEngineTests: XCTestCase {
	static let macModel = "Systran/faster-distil-whisper-small.en"
	static let macKey = "sk-mac-only-secret"
	/// What the iPhone used to send: a model the speech server does not have.
	static let phoneModel = "Systran/faster-whisper-large-v3"

	var upstream: FakeSpeechServer!
	var selection: FixedSelection!
	var keys: MemorySpeechKeyStore!
	var engine: FakeEngine!
	var helper: TestDaemon!

	override func setUpWithError() throws {
		upstream = try FakeSpeechServer(installed: Self.macModel)
		selection = FixedSelection(.onDevice)
		keys = MemorySpeechKeyStore()
		engine = FakeEngine()
		helper = try TestDaemon(engine: engine, speechSelection: selection, speechKeys: keys)
	}

	override func tearDown() {
		helper.stop()
		upstream.stop()
	}

	private var remote: RemoteSpeechServer {
		RemoteSpeechServer(baseURL: upstream.baseURL, model: Self.macModel)
	}

	private func transcribe(
		_ phone: SoftPhone, model: String? = phoneModel, extra: [String: String] = [:]
	) async throws -> SoftPhone.Response {
		var fields = extra
		if let model { fields["model"] = model }
		let (body, contentType) = TestAudio.multipart(try TestAudio.wav(seconds: 1), fields: fields)
		var request = URLRequest(url: helper.baseURL.appendingPathComponent("v1/audio/transcriptions"))
		request.httpMethod = "POST"
		request.httpBody = body
		request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer \(phone.sttKey)", forHTTPHeaderField: "Authorization")
		return try await SoftPhone.send(request)
	}

	private func models(_ phone: SoftPhone) async throws -> (SoftPhone.Response, [String: Any]) {
		var request = URLRequest(url: helper.baseURL.appendingPathComponent("v1/models"))
		request.setValue("Bearer \(phone.sttKey)", forHTTPHeaderField: "Authorization")
		let response = try await SoftPhone.send(request)
		return (response, (response.json["data"] as? [[String: Any]])?.first ?? [:])
	}

	// MARK: Remote engine (speaches, OpenAI, …)

	func testRemoteEngineUsesTheMacsModelAndKeyWhateverThePhoneSends() async throws {
		selection.current = .remote(remote)
		try keys.setCredential(SpeechServerCredential(baseURL: upstream.baseURL, key: Self.macKey))
		let phone = try await helper.pairedPhone()

		let response = try await transcribe(phone, extra: ["language": "en", "response_format": "json"])
		XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
		XCTAssertEqual(response.json["text"] as? String, "hello from the speech server")
		let seen = try XCTUnwrap(upstream.requests.last)
		XCTAssertEqual(seen.model, Self.macModel)
		XCTAssertEqual(seen.authorization, "Bearer \(Self.macKey)")
		XCTAssertEqual(seen.fields["language"], "en")
		XCTAssertEqual(seen.fields["response_format"], "json")
		XCTAssertEqual(seen.fileBytes, try TestAudio.wav(seconds: 1).count)

		// The virtual model and the omitted model are answered the same way.
		for model in [SpeechService.macModelID, nil] {
			let again = try await transcribe(phone, model: model)
			XCTAssertEqual(again.status, 200)
			XCTAssertEqual(upstream.requests.last?.model, Self.macModel)
		}

		let (listed, model) = try await models(phone)
		XCTAssertEqual(listed.status, 200)
		XCTAssertEqual((listed.json["data"] as? [Any])?.count, 1)
		XCTAssertEqual(model["id"] as? String, "whispera-mac")
		XCTAssertEqual(model["engine_kind"] as? String, "remote")
		XCTAssertEqual(model["engine"] as? String, "127.0.0.1 · \(Self.macModel)")
		XCTAssertEqual(model["ready"] as? Bool, true)
		XCTAssertFalse(String(decoding: listed.body, as: UTF8.self).contains(Self.macKey))
		XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(Self.macKey))
		XCTAssertEqual(helper.daemon.status().sttEngine, "127.0.0.1 · \(Self.macModel)")
		XCTAssertEqual(helper.daemon.status().sttMode, "remote")
	}

	func testTheKeyIsOnlySentToTheAddressItWasHandedFor() async throws {
		selection.current = .remote(remote)
		try keys.setCredential(SpeechServerCredential(baseURL: "https://api.openai.com/v1", key: Self.macKey))
		let phone = try await helper.pairedPhone()
		let response = try await transcribe(phone)
		XCTAssertEqual(response.status, 200)
		XCTAssertNil(upstream.requests.last?.authorization)
	}

	func testTheSpeechServersOwnErrorReachesThePhoneVerbatim() async throws {
		selection.current = .remote(RemoteSpeechServer(baseURL: upstream.baseURL, model: "not/installed"))
		let phone = try await helper.pairedPhone()
		let response = try await transcribe(phone)
		XCTAssertEqual(response.status, 404)
		XCTAssertEqual(response.body, FakeSpeechServer.notInstalledBody("not/installed"))
		let (_, model) = try await models(phone)
		XCTAssertEqual(model["ready"] as? Bool, false)
		XCTAssertTrue((model["message"] as? String)?.contains("doesn't have the selected model") == true)
	}

	func testAnUnreachableSpeechServerSaysWhichOne() async throws {
		selection.current = .remote(RemoteSpeechServer(baseURL: "http://127.0.0.1:9/v1", model: Self.macModel))
		let phone = try await helper.pairedPhone()
		let response = try await transcribe(phone)
		XCTAssertEqual(response.status, 502)
		XCTAssertEqual(
			(response.json["error"] as? [String: Any])?["message"] as? String,
			"The Mac couldn't reach its speech server at http://127.0.0.1:9/v1")
		let (_, model) = try await models(phone)
		XCTAssertEqual(model["ready"] as? Bool, false)
		XCTAssertTrue((model["message"] as? String)?.contains("couldn't reach") == true)
	}

	func testARemoteEngineWithoutAModelOrAddressSaysWhatToFixOnTheMac() async throws {
		let phone = try await helper.pairedPhone()
		selection.current = .remote(RemoteSpeechServer(baseURL: upstream.baseURL, model: ""))
		let noModel = try await transcribe(phone)
		XCTAssertEqual(noModel.status, 503)
		XCTAssertEqual(noModel.errorCode, "engine_unavailable")
		XCTAssertEqual(
			(noModel.json["error"] as? [String: Any])?["message"] as? String, SpeechService.noServerModel)

		selection.current = AppSpeechSelection.route(engine: "realtimeDirect", speechURL: "", speechModel: "")
		let noAddress = try await transcribe(phone)
		XCTAssertEqual(noAddress.status, 503)
		XCTAssertEqual(
			(noAddress.json["error"] as? [String: Any])?["message"] as? String, AppSpeechSelection.notSetUp)
		XCTAssertTrue(upstream.requests.isEmpty)
		let (_, model) = try await models(phone)
		XCTAssertEqual(model["ready"] as? Bool, false)
		XCTAssertEqual(model["message"] as? String, AppSpeechSelection.notSetUp)
	}

	// MARK: On-device engine (WhisperKit)

	func testOnDeviceEngineAnswersWhateverModelThePhoneSends() async throws {
		let phone = try await helper.pairedPhone()
		let response = try await transcribe(phone)
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(response.json["text"] as? String, "hello from the mac")
		XCTAssertTrue(upstream.requests.isEmpty)
		let (_, model) = try await models(phone)
		XCTAssertEqual(model["id"] as? String, "whispera-mac")
		XCTAssertEqual(model["engine_kind"] as? String, "on-device")
		XCTAssertEqual(model["engine"] as? String, "On-device · openai_whisper-small")
		XCTAssertEqual(model["ready"] as? Bool, true)
	}

	func testOnDeviceWithoutAModelIsAClearErrorNotModelNotFound() async throws {
		engine.models = []
		let phone = try await helper.pairedPhone()
		let response = try await transcribe(phone)
		XCTAssertEqual(response.status, 503)
		let error = try XCTUnwrap(response.json["error"] as? [String: Any])
		XCTAssertEqual(error["code"] as? String, "model_not_ready")
		XCTAssertEqual(
			error["message"] as? String,
			"Mac has no transcription model ready — open Whispera ▸ Settings to download one.")
		XCTAssertEqual(error["type"] as? String, "upstream_error")
		let (listed, model) = try await models(phone)
		XCTAssertEqual(listed.status, 200)
		XCTAssertEqual(model["ready"] as? Bool, false)
	}

	func testSwitchingTheEngineOnTheMacTakesEffectOnTheNextRequest() async throws {
		let phone = try await helper.pairedPhone()
		let first = try await transcribe(phone)
		XCTAssertEqual(first.json["text"] as? String, "hello from the mac")
		selection.current = .remote(remote)
		let second = try await transcribe(phone)
		XCTAssertEqual(second.json["text"] as? String, "hello from the speech server")
	}

	// MARK: Whispera's settings and the key hand-over

	func testWhisperasEngineSettingsMapToARoute() {
		let base = "http://192.168.50.140:8000/v1"
		let server = MacSpeechRoute.remote(RemoteSpeechServer(baseURL: base, model: Self.macModel))
		XCTAssertEqual(
			AppSpeechSelection.route(engine: nil, speechURL: base, speechModel: Self.macModel), .onDevice)
		XCTAssertEqual(
			AppSpeechSelection.route(engine: "whisperKit", speechURL: base, speechModel: Self.macModel), .onDevice
		)
		XCTAssertEqual(
			AppSpeechSelection.route(engine: "realtimeDirect", speechURL: base, speechModel: Self.macModel),
			server)
		XCTAssertEqual(
			AppSpeechSelection.route(
				engine: "whisperViaBYOK", speechURL: "192.168.50.140:8000", speechModel: Self.macModel), server)
		XCTAssertEqual(
			AppSpeechSelection.route(engine: "auto", speechURL: base, speechModel: Self.macModel), server)
		XCTAssertEqual(AppSpeechSelection.route(engine: "auto", speechURL: "", speechModel: ""), .onDevice)
		XCTAssertEqual(
			AppSpeechSelection.route(engine: "realtimeDirect", speechURL: "  ", speechModel: ""),
			.unavailable(AppSpeechSelection.notSetUp))
		XCTAssertEqual(AppSpeechSelection.normalize("api.openai.com"), "http://api.openai.com/v1")
		XCTAssertEqual(AppSpeechSelection.normalize("https://api.openai.com/v1/"), "https://api.openai.com/v1")
		XCTAssertEqual(RemoteSpeechServer(baseURL: "https://api.openai.com/v1", model: "whisper-1").label, "OpenAI")
		XCTAssertEqual(
			AppSpeechSelection.appDomain(helperBundleIdentifier: "com.macwhisper.app.LinkHelper"),
			"com.macwhisper.app")
		XCTAssertEqual(
			AppSpeechSelection.appDomain(helperBundleIdentifier: "com.macwhisper.app.debug.LinkHelper"),
			"com.macwhisper.app.debug")
	}

	func testSelectionIsReadFromTheAppsPreferencesOnEveryRequest() throws {
		let domain = "test.whispera.link.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let selection = AppSpeechSelection(domain: domain)
		defaults.set("whisperKit", forKey: AppSpeechSelection.engineKey)
		defaults.set("192.168.50.140:8000", forKey: AppSpeechSelection.speechURLKey)
		defaults.set(Self.macModel, forKey: AppSpeechSelection.speechModelKey)
		defaults.synchronize()
		XCTAssertEqual(selection.route(), .onDevice)
		defaults.set("realtimeDirect", forKey: AppSpeechSelection.engineKey)
		defaults.synchronize()
		XCTAssertEqual(
			selection.route(),
			.remote(RemoteSpeechServer(baseURL: "http://192.168.50.140:8000/v1", model: Self.macModel)))
	}

	func testTheAppHandsTheKeyOverBoundToItsAddressAndCanTakeItBack() throws {
		_ = try helper.daemon.setSpeechServerKey(baseURL: "192.168.50.140:8000", key: " \(Self.macKey)\n")
		XCTAssertEqual(
			keys.credential(), SpeechServerCredential(baseURL: "http://192.168.50.140:8000/v1", key: Self.macKey))
		XCTAssertThrowsError(try helper.daemon.setSpeechServerKey(baseURL: "", key: Self.macKey))
		_ = try helper.daemon.setSpeechServerKey(baseURL: "", key: "")
		XCTAssertNil(keys.credential())
	}

	func testReplacingTheModelKeepsEveryOtherPartByteForByte() throws {
		let audio = Data((0..<256).map { UInt8($0) })
		let (body, contentType) = TestAudio.multipart(
			audio, fields: ["model": Self.phoneModel, "language": "en", "prompt": "Whispera"])
		let form = try MultipartForm(body: body, contentType: contentType)
		let rewritten = try MultipartForm(
			body: form.encoded(replacing: "model", with: Self.macModel),
			contentType: "multipart/form-data; boundary=\(form.boundary)")
		XCTAssertEqual(rewritten.fields, ["model": Self.macModel, "language": "en", "prompt": "Whispera"])
		XCTAssertEqual(rewritten.file?.data, audio)
		XCTAssertEqual(rewritten.file?.filename, "clip.wav")
		let dropped = try MultipartForm(
			body: form.encoded(replacing: "model", with: nil),
			contentType: "multipart/form-data; boundary=\(form.boundary)")
		XCTAssertNil(dropped.fields["model"])
	}
}

/// A selection the test sets directly.
final class FixedSelection: MacSpeechSelecting, @unchecked Sendable {
	private let lock = NSLock()
	private var stored: MacSpeechRoute

	init(_ route: MacSpeechRoute) {
		stored = route
	}

	var current: MacSpeechRoute {
		get {
			lock.lock()
			defer { lock.unlock() }
			return stored
		}
		set {
			lock.lock()
			stored = newValue
			lock.unlock()
		}
	}

	func route() -> MacSpeechRoute { current }
}

/// A speaches-shaped speech server on loopback: it transcribes with the one installed model and
/// answers speaches' 404 for any other.
final class FakeSpeechServer: @unchecked Sendable {
	struct Seen {
		var model: String?
		var authorization: String?
		var fields: [String: String]
		var fileBytes: Int
	}

	private let server: HTTPServer
	private let lock = NSLock()
	private var seen: [Seen] = []
	let port: Int

	var baseURL: String { "http://127.0.0.1:\(port)/v1" }
	var requests: [Seen] {
		lock.lock()
		defer { lock.unlock() }
		return seen
	}

	static func notInstalledBody(_ model: String) -> Data {
		Data(
			#"{"detail":"model '\#(model)' is not installed locally. You can download the model using POST /v1/models"}"#
				.utf8)
	}

	init(installed: String) throws {
		let box = Box()
		server = HTTPServer(host: "127.0.0.1", port: 0, advertisement: nil) { exchange in box.handle?(exchange) }
		port = try server.start()
		box.handle = { [weak self] exchange in self?.handle(exchange, installed: installed) }
	}

	private func handle(_ exchange: HTTPExchange, installed: String) {
		if exchange.method == "GET", exchange.path == "/v1/models" {
			return exchange.respond(200, body: WireJSON.encode(["data": [["id": installed]]]))
		}
		guard exchange.method == "POST", exchange.path == "/v1/audio/transcriptions" else {
			return exchange.respond(404, body: Data(#"{"detail":"Not Found"}"#.utf8))
		}
		let length = Int(exchange.header("Content-Length") ?? "0") ?? 0
		guard let body = try? exchange.readBody(length),
			let form = try? MultipartForm(body: body, contentType: exchange.header("Content-Type"))
		else { return exchange.respond(400, body: Data(#"{"detail":"bad form"}"#.utf8)) }
		lock.lock()
		seen.append(
			Seen(
				model: form.fields["model"], authorization: exchange.header("Authorization"),
				fields: form.fields,
				fileBytes: form.file?.data.count ?? 0))
		lock.unlock()
		guard form.fields["model"] == installed else {
			return exchange.respond(404, body: Self.notInstalledBody(form.fields["model"] ?? ""))
		}
		exchange.respond(200, body: Data(#"{"text":"hello from the speech server"}"#.utf8))
	}

	func stop() { server.stop() }

	private final class Box: @unchecked Sendable {
		var handle: ((HTTPExchange) -> Void)?
	}
}
