import Foundation
import XCTest

@testable import LinkHelperCore

/// `POST /v1/audio/transcriptions/file` and `translations/file`: audio uploaded with
/// `POST /v1/files/{id}`, named by id in a small signed JSON request. The way dictation works
/// over the relay, where one request can't carry the audio.
final class SpeechByFileTests: XCTestCase {
	var engine: FakeEngine!
	var helper: TestDaemon!

	override func setUpWithError() throws {
		engine = FakeEngine()
		helper = try TestDaemon(engine: engine)
	}

	override func tearDown() {
		helper.stop()
	}

	private func upload(_ phone: SoftPhone, _ audio: Data, name: String = "dictation.wav", upTo end: Int? = nil) async throws -> String {
		let id = UUID().uuidString.lowercased()
		var offset = 0
		while offset < (end ?? audio.count) {
			let chunk = audio.subdata(in: offset..<min(offset + 24 * 1024, audio.count))
			let answer = try await phone.call("POST", "/v1/files/\(id)", json: [
				"name": name, "total_bytes": audio.count, "offset": offset, "data": chunk.base64EncodedString(),
			])
			XCTAssertEqual(answer.status, 200, String(decoding: answer.body, as: UTF8.self))
			offset += chunk.count
		}
		return id
	}

	private func folder(_ phone: SoftPhone, _ id: String) -> URL {
		helper.directory.appendingPathComponent("state/submissions/\(phone.deviceID)/files/\(id)")
	}

	func testRoutesAndCapability() async throws {
		XCTAssertEqual(LinkAPI.match("POST", "/v1/audio/transcriptions/file")?.name, "stt.file.transcriptions")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/audio/translations/file")?.name, "stt.file.translations")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/audio/transcriptions/file")?.auth, .signed)
		XCTAssertEqual(LinkAPI.match("POST", "/v1/audio/transcriptions/file")?.body, .json)
		XCTAssertNil(LinkAPI.match("POST", "/v1/audio/other/file"))
		XCTAssertNil(LinkAPI.match("GET", "/v1/audio/transcriptions/file"))
		let phone = try await helper.pairedPhone()
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("audio_by_file"))
	}

	func testUploadedAudioIsTranscribedWithItsFieldsThenDeleted() async throws {
		let phone = try await helper.pairedPhone()
		let audio = try TestAudio.wav(seconds: 2)
		let id = try await upload(phone, audio)
		let response = try await phone.call("POST", "/v1/audio/transcriptions/file", json: [
			"file_id": id, "language": "ru", "response_format": "verbose_json", "prompt": "names", "temperature": 0,
		])
		XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
		XCTAssertEqual(response.json["text"] as? String, "hello from the mac")
		XCTAssertEqual(response.json["language"] as? String, "ru")
		XCTAssertEqual(response.json["task"] as? String, "transcribe")
		XCTAssertEqual(engine.lastLanguage, "ru")
		XCTAssertEqual(engine.lastSampleCount, 32_000, "2 s at 16 kHz: the whole upload was decoded")
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder(phone, id).path))
		let log = try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8)
		XCTAssertTrue(log.contains("stt.file_done"))
	}

	func testTranslationsByFile() async throws {
		let phone = try await helper.pairedPhone()
		let id = try await upload(phone, try TestAudio.wav(seconds: 1))
		let response = try await phone.call("POST", "/v1/audio/translations/file", json: ["file_id": id, "response_format": "verbose_json"])
		XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
		XCTAssertEqual(response.json["text"] as? String, "translated by the mac")
		XCTAssertEqual(response.json["language"] as? String, "en")
		XCTAssertEqual(engine.translations, 1)
	}

	func testOnlyTheUploadingPhonesFinishedFileCounts() async throws {
		let phone = try await helper.pairedPhone()
		let other = try await helper.pairedPhone()
		let audio = try TestAudio.wav(seconds: 1)
		let id = try await upload(phone, audio)

		let foreign = try await other.call("POST", "/v1/audio/transcriptions/file", json: ["file_id": id])
		XCTAssertEqual(foreign.status, 404)
		XCTAssertEqual(foreign.errorCode, "file_not_found")
		XCTAssertTrue(FileManager.default.fileExists(atPath: folder(phone, id).path), "another phone can't consume it")

		let partial = try await upload(phone, audio, upTo: 1)
		let incomplete = try await phone.call("POST", "/v1/audio/transcriptions/file", json: ["file_id": partial])
		XCTAssertEqual(incomplete.status, 400)
		XCTAssertEqual(incomplete.errorCode, "file_incomplete")

		let unknown = try await phone.call("POST", "/v1/audio/transcriptions/file", json: ["file_id": UUID().uuidString.lowercased()])
		XCTAssertEqual(unknown.errorCode, "file_not_found")
	}

	func testTheRequestIsChecked() async throws {
		let phone = try await helper.pairedPhone()
		for body: [String: Any] in [
			[:], ["file_id": "not-a-uuid"], ["file_id": UUID().uuidString, "extra": 1],
			["file_id": UUID().uuidString, "response_format": "srt"], ["file_id": UUID().uuidString, "temperature": 3],
			["file_id": UUID().uuidString, "temperature": true], ["file_id": UUID().uuidString, "language": "en; rm"],
		] {
			let response = try await phone.call("POST", "/v1/audio/transcriptions/file", json: body)
			XCTAssertEqual(response.status, 400, "\(body)")
			XCTAssertEqual(response.errorCode, "bad_request", "\(body)")
		}
		// A bare STT bearer is not enough: the route is signed like the upload it reads.
		var request = URLRequest(url: helper.baseURL.appendingPathComponent("v1/audio/transcriptions/file"))
		request.httpMethod = "POST"
		request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": UUID().uuidString])
		request.setValue("Bearer \(phone.sttKey)", forHTTPHeaderField: "Authorization")
		let bearer = try await SoftPhone.send(request)
		XCTAssertEqual(bearer.status, 401)
		XCTAssertEqual(bearer.errorCode, "auth_missing")
	}

	func testAnEngineFailureStillDeletesTheUpload() async throws {
		engine.models = []
		let phone = try await helper.pairedPhone()
		let id = try await upload(phone, try TestAudio.wav(seconds: 1))
		let response = try await phone.call("POST", "/v1/audio/transcriptions/file", json: ["file_id": id])
		XCTAssertEqual(response.status, 503)
		XCTAssertEqual(response.errorCode, "model_not_ready")
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder(phone, id).path))
	}
}
