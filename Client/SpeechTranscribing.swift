// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// One model an engine can run. A local engine downloads these; a remote engine
/// lists what its server already holds, which is why `isDownloaded` is `true`
/// for everything a server offers.
struct TranscriptionModelInfo: Identifiable, Hashable, Sendable {
	let id: String
	let displayName: String
	let isDownloaded: Bool

	init(id: String, displayName: String? = nil, isDownloaded: Bool = true) {
		self.id = id
		self.displayName = displayName ?? id
		self.isDownloaded = isDownloaded
	}
}

/// What an engine can actually do. Callers branch on capability, never on which
/// engine is selected: a `switch` over engine identity is what WHI-58 removed,
/// and re-introducing one would put it straight back.
struct TranscriptionCapabilities: OptionSet, Sendable, Hashable {
	let rawValue: Int

	init(rawValue: Int) { self.rawValue = rawValue }

	static let fileTranscription = TranscriptionCapabilities(rawValue: 1 << 0)
	static let bufferTranscription = TranscriptionCapabilities(rawValue: 1 << 1)
	static let timestamps = TranscriptionCapabilities(rawValue: 1 << 2)
	static let streaming = TranscriptionCapabilities(rawValue: 1 << 3)
	/// The engine owns model files, so listing, downloading and download
	/// progress mean something. A server-side engine leaves this off.
	static let managedModels = TranscriptionCapabilities(rawValue: 1 << 4)
	static let translation = TranscriptionCapabilities(rawValue: 1 << 5)
}

/// An engine-neutral transcription request. Engine-specific tuning — WhisperKit's
/// sample length, prefill caches, temperature fallbacks — stays inside the
/// conformer that understands it, so a second engine never has to widen this.
struct TranscriptionOptions: Sendable, Equatable {
	enum Mode: String, Sendable {
		case transcribe
		case translate
	}

	var mode: Mode
	/// Language code the engine understands, or nil to let the engine decide.
	var language: String?

	init(mode: Mode = .transcribe, language: String? = nil) {
		self.mode = mode
		self.language = language
	}

	/// The options a dictation should run with. `language` stays nil so each
	/// engine applies its own default; WhisperKit reads the user's saved
	/// language itself, exactly as it did before the protocol existed.
	static func dictation(translate: Bool) -> Self {
		TranscriptionOptions(mode: translate ? .translate : .transcribe)
	}
}

/// Lifecycle as the UI needs it, rather than as any one engine implements it.
enum TranscriptionEngineState: Equatable, Sendable {
	/// Needs setup before it can run: no model downloaded, no key, no endpoint.
	case unavailable(String)
	case preparing(progress: Double, status: String)
	case ready
}

enum TranscriptionEngineError: LocalizedError, Equatable {
	case unsupported(engine: String, capability: String)
	case notConfigured(String)
	case failed(String)

	var errorDescription: String? {
		switch self {
		case .unsupported(let engine, let capability):
			return "\(engine) cannot \(capability)."
		case .notConfigured(let message):
			return message
		case .failed(let message):
			return message
		}
	}
}

/// Audio in, text out.
///
/// One interface over an on-device CoreML model and a socket to a server: which
/// of the two is running is the router's business and the conformer's, never the
/// caller's. Mirrors `RecipeExecuting` + `RecipeRouter`. See WHI-58.
///
/// Streaming conformers publish into `LiveTranscriptionState.shared` rather than
/// owning any view, so every engine reaches the one live-transcription HUD.
@MainActor
protocol SpeechTranscribing: AnyObject {
	nonisolated var engine: TranscriptionEngine { get }
	nonisolated var capabilities: TranscriptionCapabilities { get }

	var state: TranscriptionEngineState { get }

	/// Brings the engine to `.ready`, or throws saying why it cannot get there.
	func prepare() async throws
	/// Releases whatever `prepare()` acquired: an unloaded model, a closed socket.
	func shutdown()

	// MARK: Models

	var activeModel: String? { get }
	func models() async throws -> [TranscriptionModelInfo]
	func selectModel(_ id: String) async throws
	func downloadModel(_ id: String) async throws
	func cancelModelDownload()

	// MARK: One-shot transcription

	func transcribe(fileAt url: URL, options: TranscriptionOptions) async throws -> String
	func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String
	func transcribeWithTimestamps(fileAt url: URL, options: TranscriptionOptions) async throws
		-> [TranscriptionSegment]

	// MARK: Streaming

	/// Raw capture buffers, for level metering. Set by whoever drives the engine.
	var onLiveAudioSamples: (@MainActor ([Float]) -> Void)? { get set }
	/// Drops everything left over from a previous streaming session.
	func resetStreamingSession()
	/// Shows the waiting UI, brings capture up, and starts publishing into
	/// `LiveTranscriptionState.shared`. Returns once capture is established.
	func startStreaming(options: TranscriptionOptions) async throws
	/// Moves an established stream onto the input device the user just picked.
	func switchStreamingDevice() async
	func stopStreaming()
}

/// Defaults so a conformer writes only what it can actually do. Anything it
/// cannot do throws a message naming the engine, which is what the caller
/// surfaces — WHI-42's rule that a failure never silently degrades to another
/// engine holds here too.
extension SpeechTranscribing {
	var activeModel: String? { nil }

	func models() async throws -> [TranscriptionModelInfo] { [] }

	func selectModel(_ id: String) async throws {
		throw TranscriptionEngineError.unsupported(
			engine: engine.displayName, capability: "choose a model")
	}

	func downloadModel(_ id: String) async throws {
		throw TranscriptionEngineError.unsupported(
			engine: engine.displayName, capability: "download models")
	}

	func cancelModelDownload() {}

	func shutdown() {}

	func transcribeWithTimestamps(fileAt url: URL, options: TranscriptionOptions) async throws
		-> [TranscriptionSegment]
	{
		throw TranscriptionEngineError.unsupported(
			engine: engine.displayName, capability: "produce timestamps")
	}

	func resetStreamingSession() {
		LiveTranscriptionState.shared.reset()
	}

	func startStreaming(options: TranscriptionOptions) async throws {
		throw TranscriptionEngineError.unsupported(
			engine: engine.displayName, capability: "transcribe live")
	}

	func switchStreamingDevice() async {}

	func stopStreaming() {}
}
