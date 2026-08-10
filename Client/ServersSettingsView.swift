// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI
import WhisperaDictation

extension StreamingGranularity {
	/// Plain words for the server list — a user choosing a server should not
	/// need to know what a delta is, only how soon words show up.
	var plainWords: String {
		switch self {
		case .nativeDelta: return "word-by-word"
		case .synthesizedDelta: return "near-live"
		case .utterance: return "at the end"
		}
	}
}

/// The Servers tab: every remote endpoint Whispera talks to, in one place —
/// speech servers (the transcription engine and whatever URL/model it needs)
/// and LLM servers (where recipe steps run). Grew out of the engine picker
/// that used to hide inside General → Transcription and the separate "AI Mode"
/// tab; the user-visible model is now "these are my servers".
struct ServersSettingsView: View {
	@AppStorage(WhisperaSettings.transcriptionEngineKey) private var transcriptionEngineRaw =
		TranscriptionEngine.auto.rawValue
	@AppStorage(WhisperaSettings.transcriptionBackendURLKey) private var backendURL = ""
	@AppStorage(WhisperaSettings.transcriptionDirectURLKey) private var directURL = ""
	@AppStorage(WhisperaSettings.transcriptionServerIdKey) private var pinnedServerId = ""
	@AppStorage(WhisperaSettings.transcriptionDirectModelKey) private var directModel = ""
	@AppStorage("enableStreaming") private var enableStreaming = Constants.enableStreamingDefault

	/// Falls back to `auto` for the same reason `WhisperaSettings` does: a stored
	/// engine from a build that shipped one we no longer do must degrade, not trap.
	private var selectedEngine: TranscriptionEngine {
		TranscriptionEngine(rawValue: transcriptionEngineRaw) ?? .auto
	}

	// Discovery list for the backend engines (auto + whisperaStreaming). Empty
	// with no error means "not fetched yet"; a failed fetch keeps the pin row
	// visible so a stale pin stays clearable even when the backend is down.
	@State private var discoveredServers: [DiscoveredServer] = []
	@State private var isFetchingServers = false
	@State private var serverFetchError: String?

	// Direct-mode ("realtimeDirect") model list: fetched from the engine's own
	// /models endpoint rather than typed by hand. Empty + no error means "not
	// fetched yet", which is also the state a failed fetch falls back to, so the
	// free-text field underneath stays reachable either way.
	@State private var directModelOptions: [TranscriptionModelInfo] = []
	@State private var isFetchingDirectModels = false
	@State private var directModelFetchError: String?

	// Automatic engine: what it currently resolves to, refreshed whenever the
	// picker lands on it. Same shape as the model fetches above.
	@State private var autoResolutionCaption = "Deciding…"
	@State private var isResolvingAutoEngine = false

	private var usesBackendServers: Bool {
		selectedEngine == .auto || selectedEngine == .whisperaStreaming
	}

	var body: some View {
		ScrollView {
			VStack(spacing: 24) {
				SettingsSection("Speech Servers") {
					enginePicker

					switch selectedEngine {
					case .auto:
						autoCaption
						backendServerConfig
					case .whisperaStreaming:
						Text(
							"Streams audio to a Whispera transcription server over a WebSocket. Leave the server blank to use the backend's own default."
						)
						.font(.caption)
						.foregroundColor(.secondary)
						backendServerConfig
					case .realtimeDirect:
						directEngineConfig
					case .whisperKit:
						Text(
							"Runs entirely on this Mac with the model chosen under General → Whisper Model. No server and no network involved."
						)
						.font(.caption)
						.foregroundColor(.secondary)
					case .whisperViaBYOK:
						Text(
							"Sends each recording to OpenAI's transcription API with your own key, straight from this Mac. No Whispera server involved."
						)
						.font(.caption)
						.foregroundColor(.secondary)
					}

					// `auto` is included alongside the server engines: it may resolve to
					// one, and the wording below is already engine-agnostic — the
					// caveat is exactly as true when `auto` lands on WhisperKit.
					if selectedEngine.streamsFromAServer || selectedEngine == .auto {
						InfoBox(style: .info) {
							Text(
								enableStreaming
									? "Live transcription is on, so words appear while you speak. Turning it off under General → Live Transcription Mode makes Whispera record first and transcribe at the end."
									: "Live Transcription Mode is off, so nothing appears until you stop speaking and the whole recording is transcribed. Turn it on under General to see words as you say them."
							)
							.font(.caption)
							.foregroundColor(.secondary)
						}
					}
				}

				Divider()

				SettingsSection("LLM Servers") {
					Text(
						"Where recipe steps run when a dictation matches a recipe or a default command post-processes it."
					)
					.font(.caption)
					.foregroundColor(.secondary)
					LLMServersGroupView()
				}
			}
			.padding(20)
		}
	}

	// MARK: - Engine picker

	private var enginePicker: some View {
		SettingRow(
			"Engine",
			description: "Where speech-to-text runs. On-device needs no network."
		) {
			Picker("Transcription engine", selection: $transcriptionEngineRaw) {
				ForEach(TranscriptionEngine.allCases, id: \.rawValue) { engine in
					Text(engine.displayName).tag(engine.rawValue)
				}
			}
			.labelsHidden()
			.frame(width: 240)
			.accessibilityIdentifier("transcriptionEnginePicker")
			// A server engine with live transcription off records first and
			// transcribes at the end, which reads as the engine not working.
			// Choosing one turns it on; the box below says so, and the
			// toggle stays the user's.
			.onChange(of: transcriptionEngineRaw) { _, raw in
				guard TranscriptionEngine(rawValue: raw)?.streamsFromAServer == true,
					!enableStreaming
				else { return }
				enableStreaming = true
				AppLogger.shared.general.info(
					"Live transcription turned on because a server engine was selected: \(raw)")
			}
		}
	}

	private var autoCaption: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(
				"Streams through a transcription server when one is configured and reachable, preferring the one with the best live-word quality. Falls back to WhisperKit on-device otherwise. Nothing else to set up."
			)
			.font(.caption)
			.foregroundColor(.secondary)
			HStack(spacing: 6) {
				if isResolvingAutoEngine {
					ProgressView()
						.scaleEffect(0.5)
				}
				Text(autoResolutionCaption)
					.font(.caption)
					.foregroundColor(.secondary)
					.accessibilityIdentifier("autoEngineResolutionCaption")
			}
			.animation(.easeInOut(duration: 0.2), value: isResolvingAutoEngine)
		}
		.task(id: transcriptionEngineRaw) {
			guard selectedEngine == .auto else { return }
			isResolvingAutoEngine = true
			autoResolutionCaption = await AutoTranscriber.shared.resolutionCaption()
			isResolvingAutoEngine = false
		}
	}

	// MARK: - Backend engines (auto + whisperaStreaming)

	private var backendServerConfig: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				TextField(
					WhisperaSettings.serverURLString + " (leave blank to reuse the account server)",
					text: $backendURL
				)
				.textFieldStyle(.roundedBorder)
				.autocorrectionDisabled()
				.accessibilityIdentifier("transcriptionServerURLField")

				Button {
					refreshDiscoveredServers()
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(isFetchingServers)
				.accessibilityIdentifier("transcriptionServersRefreshButton")
				.help("Ask the backend which speech servers it offers")
			}

			serverList

			if let serverFetchError {
				HStack(spacing: 6) {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundColor(.orange)
						.font(.caption)
					Text(serverFetchError)
						.font(.caption)
						.foregroundColor(.orange)
				}
				.transition(.opacity)
			}

			stalePinNotice
		}
		.animation(.easeInOut(duration: 0.2), value: serverFetchError)
		.animation(.easeInOut(duration: 0.2), value: discoveredServers)
		// One task keyed on engine + URL: switching to a backend engine fetches,
		// and editing the URL re-fetches after a short pause so we do not probe
		// on every keystroke.
		.task(id: "\(transcriptionEngineRaw)|\(backendURL)") {
			try? await Task.sleep(for: .milliseconds(400))
			guard !Task.isCancelled else { return }
			refreshDiscoveredServers()
		}
	}

	@ViewBuilder
	private var serverList: some View {
		if isFetchingServers && discoveredServers.isEmpty {
			HStack(spacing: 8) {
				ProgressView()
					.scaleEffect(0.6)
				Text("Asking the backend which servers it offers…")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		} else if !discoveredServers.isEmpty {
			VStack(alignment: .leading, spacing: 4) {
				serverChoiceRow(
					isSelected: pinnedServerId.isEmpty,
					title: "Automatic (best available)",
					// Empty pin means different things per engine: `auto` ranks the
					// list itself, `whisperaStreaming` defers to the backend's default.
					detail: selectedEngine == .auto
						? "Whispera picks the server with the best live-word quality"
						: "The backend picks its own default server",
					isOnline: nil
				) {
					pinnedServerId = ""
				}
				ForEach(discoveredServers, id: \.id) { server in
					serverChoiceRow(
						isSelected: pinnedServerId == server.id,
						title: server.label,
						detail: serverDetail(for: server),
						isOnline: server.isOnline
					) {
						pinnedServerId = server.id
					}
				}
			}
		}
	}

	private func serverDetail(for server: DiscoveredServer) -> String {
		var parts: [String] = []
		if !server.model.isEmpty { parts.append(server.model) }
		parts.append("words \(server.granularity.plainWords)")
		return parts.joined(separator: " • ")
	}

	private func serverChoiceRow(
		isSelected: Bool,
		title: String,
		detail: String,
		isOnline: Bool?,
		select: @escaping () -> Void
	) -> some View {
		Button(action: select) {
			HStack(spacing: 8) {
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.foregroundColor(isSelected ? .blue : .secondary)
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.subheadline)
						.foregroundColor(.primary)
					Text(detail)
						.font(.caption)
						.foregroundColor(.secondary)
				}
				Spacer()
				if let isOnline {
					HStack(spacing: 6) {
						Circle()
							.fill(isOnline ? Color.green : Color.secondary)
							.frame(width: 8, height: 8)
						Text(isOnline ? "Online" : "Offline")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
			.padding(8)
			.background(
				isSelected ? Color.blue.opacity(0.1) : Color.clear,
				in: RoundedRectangle(cornerRadius: 8)
			)
		}
		.buttonStyle(.plain)
		.animation(.easeInOut(duration: 0.2), value: isSelected)
	}

	/// A pin that names a server the current list does not — renamed, removed,
	/// or the whole list unreachable — must stay visible and clearable: an
	/// invisible leftover pin has already silently steered `auto` before.
	@ViewBuilder
	private var stalePinNotice: some View {
		if !pinnedServerId.isEmpty, !isFetchingServers,
			!discoveredServers.contains(where: { $0.id == pinnedServerId })
		{
			HStack(spacing: 6) {
				Image(systemName: "pin.fill")
					.foregroundColor(.orange)
					.font(.caption)
				Text("Pinned to “\(pinnedServerId)”, which is not in the list above.")
					.font(.caption)
					.foregroundColor(.orange)
				Button("Clear pin") {
					pinnedServerId = ""
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.accessibilityIdentifier("clearServerPinButton")
			}
			.transition(.opacity)
		}
	}

	private func refreshDiscoveredServers() {
		guard usesBackendServers else { return }
		isFetchingServers = true
		serverFetchError = nil
		Task { @MainActor in
			do {
				guard let baseURL = WhisperaSettings.transcriptionBackendURL else {
					throw StreamingTranscriberError.invalidServerURL
				}
				// Same credential shape the dictation socket uses; an empty token is
				// fine against a self-hosted backend that requires none.
				let credentials = DictationCredentialProvider.refreshingBearer {
					(try? AuthTokenStore.shared.load()).flatMap { $0.isEmpty ? nil : $0 } ?? ""
				}
				discoveredServers = try await ServerDiscoveryProbe.fetch(
					baseURL: baseURL,
					credentials: credentials,
					session: .shared,
					timeout: 5)
				serverFetchError = nil
			} catch {
				AppLogger.shared.general.error(
					"Failed to list transcription servers: \(error.localizedDescription)")
				discoveredServers = []
				serverFetchError = "Server unreachable — check the URL."
			}
			isFetchingServers = false
		}
	}

	// MARK: - Direct engine (realtimeDirect)

	private var directEngineConfig: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(
				"Streams audio straight to an OpenAI-Realtime engine, with no Whispera backend in between. The engine holds its own credentials, so use this only on a network you trust."
			)
			.font(.caption)
			.foregroundColor(.secondary)
			TextField("http://192.168.0.10:8000/v1", text: $directURL)
				.textFieldStyle(.roundedBorder)
				.autocorrectionDisabled()
				.accessibilityIdentifier("directEngineURLField")

			HStack(spacing: 8) {
				if isFetchingDirectModels {
					ProgressView()
						.scaleEffect(0.6)
					Text("Checking the engine for installed models…")
						.font(.caption)
						.foregroundColor(.secondary)
				} else if !directModelOptions.isEmpty {
					Picker("Model", selection: $directModel) {
						ForEach(directModelOptions) { model in
							Text(model.displayName).tag(model.id)
						}
					}
					.labelsHidden()
					.frame(width: 260)
					.accessibilityIdentifier("directEngineModelPicker")
				} else {
					// Fallback: the fetch never ran or it failed. Typing a
					// model by hand keeps the engine reachable even when
					// Whispera cannot list what it has installed.
					TextField(
						"Model (e.g. Systran/faster-distil-whisper-large-v3)",
						text: $directModel
					)
					.textFieldStyle(.roundedBorder)
					.autocorrectionDisabled()
					.accessibilityIdentifier("directEngineModelField")
				}

				Button {
					refreshDirectModels()
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(isFetchingDirectModels)
				.accessibilityIdentifier("directEngineModelsRefreshButton")
				.help("Ask the engine what speech-to-text models it has installed")
			}
			.animation(.easeInOut(duration: 0.2), value: isFetchingDirectModels)
			.animation(.easeInOut(duration: 0.2), value: directModelOptions)

			if let directModelFetchError {
				HStack(spacing: 6) {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundColor(.orange)
						.font(.caption)
					Text(directModelFetchError)
						.font(.caption)
						.foregroundColor(.orange)
				}
				.transition(.opacity)
			}

			Text(
				"The URL is the engine's OpenAI-compatible base, ending in /v1. Refresh to list the models it already has installed, or type one directly if it cannot be reached right now."
			)
			.font(.caption)
			.foregroundColor(.secondary)
		}
		.animation(.easeInOut(duration: 0.2), value: directModelFetchError)
		.task(id: transcriptionEngineRaw) {
			guard directModelOptions.isEmpty, directModelFetchError == nil else { return }
			refreshDirectModels()
		}
	}

	/// Asks the directly-addressed engine what speech-to-text models it has
	/// installed. A failure keeps whatever model string is already saved and
	/// falls back to the free-text field rather than clearing the selection —
	/// an engine that is briefly unreachable should not cost the user their
	/// configured model.
	private func refreshDirectModels() {
		isFetchingDirectModels = true
		directModelFetchError = nil
		Task { @MainActor in
			do {
				let models = try await StreamingTranscriber.direct.models()
				directModelOptions = models
				isFetchingDirectModels = false
			} catch {
				AppLogger.shared.general.error(
					"Failed to list direct-engine models: \(error.localizedDescription)")
				directModelOptions = []
				// StreamingTranscriberError distinguishes "unreachable" from
				// "reachable but no speech models", and both messages already say
				// what to check — keep them instead of flattening to one line.
				directModelFetchError = error.localizedDescription
				isFetchingDirectModels = false
			}
		}
	}
}
