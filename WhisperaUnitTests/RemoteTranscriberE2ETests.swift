import Foundation
import Testing

@testable import Whispera

private final class FixtureAnchor {}

/// Live transcription against a real OpenAI-compatible Whisper server
/// (speaches on the LAN). Opt-in via `WHISPERA_E2E=1`. Exercises the same
/// client code path the BYOK and via-Whispera engines use.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WHISPERA_E2E"] == "1"))
struct RemoteTranscriberE2ETests {

	/// Loopback so the headless test host isn't blocked by macOS Local Network
	/// privacy. Point an SSH tunnel here: ssh -fN -L 8001:<whisper-host>:8000 ...
	private let endpoint = URL(string: "http://localhost:8001/v1/audio/transcriptions")!
	private let model = "Systran/faster-distil-whisper-large-v3"

	private func clip() throws -> Data {
		let bundle = Bundle(for: FixtureAnchor.self)
		let url = try #require(bundle.url(forResource: "clip", withExtension: "wav"))
		return try Data(contentsOf: url)
	}

	@Test func transcribesRealAudioViaOpenAICompatibleWhisper() async throws {
		let audio = try clip()
		let keyStore = ByokKeyStore(service: "com.whispera.byok.test.\(UUID().uuidString)")
		defer { try? keyStore.delete(provider: .openai) }
		try keyStore.save(provider: .openai, key: "sk-speaches-ignored")

		let transcriber = RemoteTranscriber(keyStore: keyStore, openAITranscribeURL: endpoint)
		let text = try await transcriber.transcribeViaBYOK(
			audio: audio, filename: "clip.wav", mimetype: "audio/wav", language: "en", model: model)

		#expect(text.lowercased().contains("professional"))
		#expect(text.lowercased().contains("file"))
	}
}
