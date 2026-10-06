import Foundation
import Testing

@testable import Whispera

struct MultipartTests {

	@Test func multipartContainsFilePartAndFields() {
		let (body, contentType) = RemoteTranscriber.multipart(
			fileField: "file", filename: "clip.wav", mimetype: "audio/wav",
			fileData: Data("AUDIOBYTES".utf8), fields: ["language": "en"])
		let text = String(data: body, encoding: .utf8)!

		#expect(contentType.hasPrefix("multipart/form-data; boundary="))
		#expect(text.contains("name=\"file\"; filename=\"clip.wav\""))
		#expect(text.contains("Content-Type: audio/wav"))
		#expect(text.contains("name=\"language\""))
		#expect(text.contains("en"))
		#expect(text.contains("AUDIOBYTES"))
	}
}

struct RemoteTranscriberTests {

	@Test func viaWhisperaSendsBearerAndReturnsText() async throws {
		let mock = MockURLProtocol.make(
			status: 200,
			json: #"{"text":"hello world","language":"en","duration":1.0,"provider":"openai-whisper"}"#)
		let store = AuthTokenStore(service: "com.whispera.clerk.test.\(UUID().uuidString)")
		defer { try? store.delete() }
		try store.save("tok")
		let transcriber = RemoteTranscriber(
			session: mock.session, tokenStore: store, serverURLProvider: { mock.baseURL })

		let text = try await transcriber.transcribeViaWhispera(
			audio: Data("x".utf8), filename: "a.wav", mimetype: "audio/wav", language: "en")
		#expect(text == "hello world")
		let req = MockURLProtocol.lastRequest(host: mock.host)
		#expect(req?.url?.path == "/transcribe")
		#expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
		#expect(req?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
	}

	@Test func viaWhisperaRequiresSignIn() async {
		let mock = MockURLProtocol.make(status: 200, json: #"{"text":"x"}"#)
		let store = AuthTokenStore(service: "com.whispera.clerk.test.\(UUID().uuidString)")
		try? store.delete()
		let transcriber = RemoteTranscriber(
			session: mock.session, tokenStore: store, serverURLProvider: { mock.baseURL })
		await #expect(throws: RemoteTranscriberError.self) {
			_ = try await transcriber.transcribeViaWhispera(
				audio: Data(), filename: "a.wav", mimetype: "audio/wav", language: nil)
		}
	}

	@Test func viaBYOKUsesKeyAndOpenAIURL() async throws {
		let mock = MockURLProtocol.make(status: 200, json: #"{"text":"byok text"}"#)
		let keyStore = ByokKeyStore(service: "com.whispera.byok.test.\(UUID().uuidString)")
		defer { try? keyStore.delete(provider: .openai) }
		try keyStore.save(provider: .openai, key: "sk-user-openai-key-123456")
		let transcriber = RemoteTranscriber(
			session: mock.session, keyStore: keyStore,
			openAITranscribeURL: mock.baseURL.appendingPathComponent("v1/audio/transcriptions"))

		let text = try await transcriber.transcribeViaBYOK(
			audio: Data("x".utf8), filename: "a.wav", mimetype: "audio/wav", language: nil)
		#expect(text == "byok text")
		let req = MockURLProtocol.lastRequest(host: mock.host)
		#expect(req?.url?.path == "/v1/audio/transcriptions")
		#expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-user-openai-key-123456")
	}

	@Test func viaBYOKRequiresKey() async {
		let mock = MockURLProtocol.make(status: 200, json: #"{"text":"x"}"#)
		let keyStore = ByokKeyStore(service: "com.whispera.byok.test.\(UUID().uuidString)")
		let transcriber = RemoteTranscriber(
			session: mock.session, keyStore: keyStore,
			openAITranscribeURL: mock.baseURL.appendingPathComponent("v1/audio/transcriptions"))
		await #expect(throws: RemoteTranscriberError.self) {
			_ = try await transcriber.transcribeViaBYOK(
				audio: Data(), filename: "a.wav", mimetype: "audio/wav", language: nil)
		}
	}

	@Test func httpErrorSurfacesNoFallback() async {
		let mock = MockURLProtocol.make(status: 500, json: #"{"error":"boom"}"#)
		let store = AuthTokenStore(service: "com.whispera.clerk.test.\(UUID().uuidString)")
		defer { try? store.delete() }
		try? store.save("tok")
		let transcriber = RemoteTranscriber(
			session: mock.session, tokenStore: store, serverURLProvider: { mock.baseURL })
		await #expect(throws: RemoteTranscriberError.self) {
			_ = try await transcriber.transcribeViaWhispera(
				audio: Data(), filename: "a.wav", mimetype: "audio/wav", language: nil)
		}
	}
}
