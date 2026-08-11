// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// The local conformer. Every member here forwards to a method that already
/// existed, so WhisperKit's behaviour is the behaviour it had before WHI-58 —
/// the protocol describes it rather than changing it.
///
/// The live decoding options stay derived from the user's persisted language and
/// translation settings inside the transcriber, which is where they were
/// derived before; `TranscriptionOptions.mode` is read only on the one-shot
/// paths, where it was already an argument.
extension WhisperKitTranscriber: SpeechTranscribing {
	nonisolated var engine: TranscriptionEngine { .whisperKit }

	nonisolated var capabilities: TranscriptionCapabilities {
		[.fileTranscription, .bufferTranscription, .timestamps, .streaming, .managedModels, .translation]
	}

	var state: TranscriptionEngineState {
		if isDownloadingModel {
			return .preparing(
				progress: downloadProgress, status: "Downloading \(downloadingModelName ?? "model")...")
		}
		if isInitializing {
			return .preparing(progress: initializationProgress, status: initializationStatus)
		}
		if isModelLoading {
			return .preparing(
				progress: loadProgress, status: "Loading \(currentModel ?? selectedModel ?? "model")...")
		}
		if isCurrentModelLoaded() { return .ready }
		if downloadedModels.isEmpty {
			return .unavailable("No model downloaded. Download one in Settings.")
		}
		return .preparing(progress: 0, status: "Waiting for model...")
	}

	func prepare() async throws {
		try await waitForReadyForTranscription()
	}

	// MARK: - Models

	var activeModel: String? { currentModel }

	func models() async throws -> [TranscriptionModelInfo] {
		if availableModels.isEmpty {
			try await refreshAvailableModels()
		}
		let downloaded = (try? await getDownloadedModels()) ?? downloadedModels
		return availableModels.map { id in
			TranscriptionModelInfo(
				id: id,
				displayName: WhisperKitTranscriber.getModelDisplayName(for: id),
				isDownloaded: downloaded.contains(id))
		}
	}

	func selectModel(_ id: String) async throws {
		try await switchModel(to: id)
	}

	// MARK: - One-shot

	func transcribe(fileAt url: URL, options: TranscriptionOptions) async throws -> String {
		try await transcribe(audioURL: url, enableTranslation: options.mode == .translate)
	}

	func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String {
		try await transcribeAudioArray(samples, enableTranslation: options.mode == .translate)
	}

	func transcribeWithTimestamps(fileAt url: URL, options: TranscriptionOptions) async throws
		-> [TranscriptionSegment]
	{
		try await transcribeFileWithTimestamps(
			at: url, enableTranslation: options.mode == .translate)
	}

	// MARK: - Streaming

	func resetStreamingSession() {
		clearLiveTranscriptionState()
	}

	func startStreaming(options: TranscriptionOptions) async throws {
		try await liveStream()
	}

	func switchStreamingDevice() async {
		await switchLiveStreamDevice()
	}

	@discardableResult
	func stopStreaming() async -> String {
		stopLiveStream()
		// stopLiveStream() confirms the pending tail synchronously, so
		// confirmedText already holds the whole transcript by the time it returns.
		return LiveTranscriptionState.shared.confirmedText.trimmingCharacters(
			in: .whitespacesAndNewlines)
	}
}
