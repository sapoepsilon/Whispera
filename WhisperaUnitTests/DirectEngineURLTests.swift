// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaDictation

@testable import Whispera

/// The base URL a direct engine actually streams to.
///
/// QA, 2026-08-23: a speech server typed as the bare host
/// `http://192.168.50.140:8000` opened `GET /realtime` and speaches answered
/// 403. The settings field normalised the address to `.../v1` for display and
/// for the reachability probe, but the streaming path re-parsed the stored
/// string raw — so the one consumer that mattered never saw the `/v1`. These
/// pin the routing at its choke point and follow it all the way to the socket
/// URL the package builds.
struct DirectEngineURLTests {
	@Test func aBareHostResolvesToTheNormalisedDirectBase() {
		let base = WhisperaSettings.transcriptionServerURL(
			engine: .realtimeDirect,
			backendURLString: "http://localhost:3000",
			directURLString: "http://192.168.50.140:8000")

		#expect(base?.absoluteString == "http://192.168.50.140:8000/v1")
	}

	@Test func aHostWithNoSchemeResolvesToTheNormalisedDirectBase() {
		let base = WhisperaSettings.transcriptionServerURL(
			engine: .realtimeDirect,
			backendURLString: "http://localhost:3000",
			directURLString: "192.168.50.140:8000")

		#expect(base?.absoluteString == "http://192.168.50.140:8000/v1")
	}

	/// The finding, end to end: bare host in, `/v1/realtime` out.
	@Test func aBareHostReachesTheRealtimeSocketUnderV1() throws {
		let base = try #require(
			WhisperaSettings.transcriptionServerURL(
				engine: .realtimeDirect,
				backendURLString: "",
				directURLString: "http://192.168.50.140:8000"))
		let endpoint = DictationConfiguration.directEngine(base, model: "whisper").endpoint

		#expect(endpoint.scheme == "ws")
		#expect(endpoint.path == "/v1/realtime")
		#expect(endpoint.absoluteString.hasPrefix("ws://192.168.50.140:8000/v1/realtime"))
	}

	@Test func anHTTPSDirectBaseReachesAWSSSocketUnderV1() throws {
		let base = try #require(
			WhisperaSettings.transcriptionServerURL(
				engine: .realtimeDirect,
				backendURLString: "",
				directURLString: "https://speech.example.com"))
		let endpoint = DictationConfiguration.directEngine(base, model: "whisper").endpoint

		#expect(endpoint.scheme == "wss")
		#expect(endpoint.path == "/v1/realtime")
	}

	/// A base the user already typed with `/v1` must not collect a second one.
	@Test func anAlreadyVersionedBaseIsLeftAlone() throws {
		let base = try #require(
			WhisperaSettings.transcriptionServerURL(
				engine: .realtimeDirect,
				backendURLString: "",
				directURLString: "http://192.168.50.140:8000/v1"))

		#expect(base.absoluteString == "http://192.168.50.140:8000/v1")
		#expect(DictationConfiguration.directEngine(base, model: "m").endpoint.path == "/v1/realtime")
	}

	/// The other half of the routing: the backend proxy is not an
	/// OpenAI-compatible base, and appending `/v1` to it would 404.
	@Test func theBackendProxyBaseIsNotNormalised() {
		for engine in [TranscriptionEngine.auto, .whisperaStreaming, .whisperKit, .whisperViaBYOK] {
			let base = WhisperaSettings.transcriptionServerURL(
				engine: engine,
				backendURLString: "http://127.0.0.1:3000",
				directURLString: "http://192.168.50.140:8000")

			#expect(base?.absoluteString == "http://127.0.0.1:3000")
		}
	}

	/// An unconfigured direct engine stays unconfigured rather than falling back
	/// to the backend's address, which is not an engine.
	@Test func anEmptyDirectBaseResolvesToNothing() {
		#expect(
			WhisperaSettings.transcriptionServerURL(
				engine: .realtimeDirect,
				backendURLString: "http://127.0.0.1:3000",
				directURLString: "") == nil)
	}
}
