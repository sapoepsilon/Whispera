// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaDictation

@testable import Whispera

/// What a user is told when a dictation fails. The rule these pin is that the
/// message names the thing that failed and what to check — a raw
/// "InternalServerError" is the failure mode, not the message.
@MainActor
struct TranscriptionFailureMessageTests {
	private func message(for error: Error) -> String {
		StreamingTranscriber.failure(for: error, destination: "speaches-lan").message
	}

	@Test func everyFailureNamesWhatFailed() {
		let errors: [DictationError] = [
			.unauthorized,
			.credentialUnavailable("keychain locked"),
			.connectionFailed("The Internet connection appears to be offline."),
			.closedUnexpectedly(code: 1006, reason: ""),
			.protocolViolation("not JSON"),
			.audioUnavailable("no input device"),
			.server(message: "InternalServerError: Internal Server Error", code: nil),
		]
		for error in errors {
			let message = self.message(for: error)
			#expect(message.hasSuffix("."), "\(error) produced a fragment: \(message)")
			#expect(message.count > 40, "\(error) produced nothing actionable: \(message)")
		}
	}

	/// The exact failure that made this work necessary: the engine's own words are
	/// not a message a user can do anything with.
	@Test func aServerErrorDoesNotEchoTheEnginesOwnWords() {
		let message = self.message(
			for: DictationError.server(message: "InternalServerError: Internal Server Error", code: nil)
		)
		#expect(!message.contains("InternalServerError"))
		#expect(message.contains("speaches-lan"))
	}

	@Test func anUnreachableServerSaysWhereToLook() {
		let message = self.message(for: DictationError.connectionFailed("offline"))
		#expect(message.contains("speaches-lan"))
		#expect(message.lowercased().contains("network"))
	}

	@Test func aRejectedCredentialPointsAtAccountSettings() {
		#expect(message(for: DictationError.unauthorized).contains("Account settings"))
		#expect(message(for: DictationError.credentialUnavailable("x")).contains("Account settings"))
	}

	@Test func aMissingMicrophonePointsAtPrivacySettings() {
		#expect(message(for: DictationError.audioUnavailable("denied")).contains("Microphone"))
	}

	/// The engine's own capture timeout already reads well; it must survive the
	/// mapping rather than be flattened into the generic fallback.
	@Test func anEngineErrorKeepsItsOwnDescription() {
		let message = self.message(for: StreamingTranscriberError.captureTimedOut)
		#expect(message == StreamingTranscriberError.captureTimedOut.errorDescription)
	}

	@Test func anUnknownErrorStillSaysWhereToLook() {
		struct Boom: Error {}
		#expect(message(for: Boom()).contains("Transcription"))
	}

	private func directMessage(for error: Error, destination: String = "http://192.168.50.140:8000/v1")
		-> String
	{
		StreamingTranscriber.failure(for: error, destination: destination, reachedVia: .direct).message
	}

	/// QA, 2026-08-23: a credential-less LAN speaches answered 403 — because the
	/// base URL had lost its `/v1` and the socket asked for `/realtime` — and the
	/// app told the user their credentials had been rejected and to sign in again
	/// under Account settings. There is no account in a direct server's path, so
	/// that screen cannot fix anything.
	@Test func aDirectServersRefusalNeverMentionsTheAccount() {
		for error: DictationError in [.unauthorized, .credentialUnavailable("none saved")] {
			let message = directMessage(for: error)
			#expect(!message.contains("Account"), "\(error) still points at Account settings")
			#expect(!message.lowercased().contains("sign in"), "\(error) still says to sign in")
		}
	}

	/// And it says what actually happened, at which address, with the check that
	/// would have found the bug.
	@Test func aDirectServersRefusalNamesTheURLTheStatusAndTheVersionPath() {
		let message = directMessage(for: DictationError.unauthorized)
		#expect(message.contains("http://192.168.50.140:8000/v1"))
		#expect(message.contains("401"))
		#expect(message.contains("403"))
		#expect(message.contains("/v1/realtime"))
	}

	/// The backend route is untouched: there the account really is the credential
	/// that was rejected.
	@Test func theBackendRouteStillPointsAtAccountSettings() {
		#expect(
			StreamingTranscriber.failure(
				for: DictationError.unauthorized, destination: "speaches-lan", reachedVia: .backend
			).message.contains("Account settings"))
	}

	/// A 401 from a server that answered is not an unreachable server, and saying
	/// so sends the user to check whether it is running instead of at the key.
	@Test func aRefusedModelListingIsNotReportedAsUnreachable() {
		let described =
			StreamingTranscriberError.engineRefused("192.168.50.140", status: 401)
			.errorDescription ?? ""
		#expect(described.contains("401"))
		#expect(described.contains("/v1"))
		#expect(!described.lowercased().contains("could not reach"))
	}
}

/// macOS's local-network gate: what it does to a LAN server, and how the app is
/// supposed to answer for it.
///
/// QA, 2026-08-23: the first connection to a LAN speaches failed with `-1009
/// (Local network prohibited)`, Whispera said "check that the server is
/// running" — it was — and the system prompt that grants the access never
/// appeared at all.
@MainActor
struct LocalNetworkAccessTests {
	@Test func privateAddressesNeedTheGrantAndLoopbackDoesNot() {
		for host in ["192.168.50.140", "10.0.0.5", "172.16.3.9", "172.31.255.1", "169.254.4.4", "nas.local"] {
			#expect(LocalNetworkAccess.needsLocalNetworkGrant(host: host), "\(host)")
		}
		for host in ["localhost", "127.0.0.1", "::1", "api.openai.com", "8.8.8.8", "172.32.0.1", "192.169.1.1"] {
			#expect(!LocalNetworkAccess.needsLocalNetworkGrant(host: host), "\(host)")
		}
	}

	/// The code is `-1009` whether the Mac is offline or the grant is missing, so
	/// only the description tells them apart — and the offline one must keep its
	/// own message.
	@Test func onlyTheLocalNetworkRefusalReadsAsADenial() {
		#expect(LocalNetworkAccess.readsAsDenial("Local network prohibited"))
		#expect(!LocalNetworkAccess.readsAsDenial("The Internet connection appears to be offline."))
	}

	@Test func aDeniedLANConnectionPointsAtTheLocalNetworkPane() {
		let advice = LocalNetworkAccess.advice(
			forFailure: "Local network prohibited", destination: "http://192.168.50.140:8000/v1")

		#expect(advice?.contains("Local Network") == true)
		#expect(advice?.contains("192.168.50.140") == true)
		#expect(advice?.lowercased().contains("check that the server is running") != true)
	}

	/// A LAN server that failed for some other reason still gets the pointer as a
	/// second thing to check, because the grant is the likeliest cause.
	@Test func anyLANFailureMentionsTheGrantAsWell() {
		let advice = LocalNetworkAccess.advice(
			forFailure: "could not connect", destination: "http://192.168.50.140:8000/v1")

		#expect(advice?.contains("Local Network") == true)
	}

	/// A public server's failure is nothing to do with local networking and must
	/// keep the ordinary message.
	@Test func aPublicServerGetsNoLocalNetworkAdvice() {
		#expect(
			LocalNetworkAccess.advice(
				forFailure: "could not connect", destination: "https://api.openai.com/v1") == nil)
		#expect(
			LocalNetworkAccess.advice(
				forFailure: "could not connect", destination: "http://localhost:8000/v1") == nil)
	}

	/// The primer exists to make the prompt appear before the first real
	/// connection. It must touch a LAN address, must not touch anything else, and
	/// must not reopen a connection per keystroke of a debounced settings field.
	@Test func thePrimerTouchesEachLANEndpointExactlyOnce() {
		var touched: [String] = []
		let primer = LocalNetworkPrimer { host, port in touched.append("\(host):\(port)") }

		#expect(primer.prime(for: URL(string: "http://192.168.50.140:8000/v1")))
		#expect(!primer.prime(for: URL(string: "http://192.168.50.140:8000/v1")))
		#expect(!primer.prime(for: URL(string: "http://192.168.50.140:8000/other")))
		#expect(primer.prime(for: URL(string: "http://192.168.50.141:8000/v1")))

		#expect(touched == ["192.168.50.140:8000", "192.168.50.141:8000"])
	}

	/// Scoped, deliberately: no sweep of the subnet, and nothing touched that
	/// does not need the grant.
	@Test func thePrimerLeavesLoopbackAndPublicAddressesAlone() {
		var touched: [String] = []
		let primer = LocalNetworkPrimer { host, port in touched.append("\(host):\(port)") }

		#expect(!primer.prime(for: URL(string: "http://localhost:8000/v1")))
		#expect(!primer.prime(for: URL(string: "https://api.openai.com/v1")))
		#expect(!primer.prime(for: nil))

		#expect(touched.isEmpty)
	}

	/// The port a bare https base implies, so the touch lands on the socket the
	/// request would have used.
	@Test func thePrimerUsesTheSchemesDefaultPortWhenNoneWasTyped() {
		var touched: [String] = []
		let primer = LocalNetworkPrimer { host, port in touched.append("\(host):\(port)") }

		#expect(primer.prime(for: URL(string: "http://nas.local/v1")))

		#expect(touched == ["nas.local:80"])
	}
}

/// Which engines need a server, which is what decides whether the URL fields and
/// the live-transcription default apply.
struct ServerEngineTests {
	@Test func onlySocketEnginesStreamFromAServer() {
		#expect(TranscriptionEngine.whisperaStreaming.streamsFromAServer)
		#expect(TranscriptionEngine.realtimeDirect.streamsFromAServer)
		#expect(!TranscriptionEngine.whisperKit.streamsFromAServer)
		#expect(!TranscriptionEngine.whisperViaBYOK.streamsFromAServer)
		// `auto` resolves to `AutoTranscriber`, not to `StreamingTranscriber`
		// itself, even on a run that ends up streaming — see
		// `everyServerEngineResolvesToTheStreamingConformer` below.
		#expect(!TranscriptionEngine.auto.streamsFromAServer)
	}

	/// Every engine that streams from a server is one the streaming conformer
	/// handles, so the two never drift apart.
	@MainActor
	@Test func everyServerEngineResolvesToTheStreamingConformer() {
		for engine in TranscriptionEngine.allCases where engine.streamsFromAServer {
			#expect(TranscriptionRouter.transcriber(for: engine) is StreamingTranscriber)
		}
	}
}
