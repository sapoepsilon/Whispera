// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI
import WhisperaDictation
import WhisperaOpenAI

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
/// the speech server (whatever runs speech-to-text) and the LLM server (where
/// recipe steps run). Both are the same shape now: a base URL, an optional key
/// and a model, edited through `ServerEntrySettingsView`. The Local/BYOK mode
/// picker that used to sit under "LLM Servers" is gone (WHI-91), and so is the
/// separate direct-engine URL block that duplicated it on the speech side.
struct ServersSettingsView: View {
	/// What the picker shows when nothing has been stored yet.
	///
	/// The fresh-install value, not `auto` — the same constant
	/// `WhisperaSettings.transcriptionEngine` degrades an absent key to. They
	/// disagreed, so a fresh install ran WhisperKit while this picker read
	/// "Automatic (recommended)" (QA, 2026-08-23). Only the *absent* case is
	/// affected: an explicit `auto` is a stored string and keeps winning. Named
	/// rather than inlined so the agreement is assertable — see
	/// `TranscriptionRouterTests.thePickerDefaultIsTheEngineAFreshInstallRuns`.
	static let defaultEngineRawValue = TranscriptionEngine.fresh.rawValue

	@AppStorage(WhisperaSettings.transcriptionEngineKey) private var transcriptionEngineRaw =
		ServersSettingsView.defaultEngineRawValue
	@AppStorage(WhisperaSettings.transcriptionBackendURLKey) private var backendURL = ""
	@AppStorage(WhisperaSettings.transcriptionServerIdKey) private var pinnedServerId = ""
	@AppStorage("enableStreaming") private var enableStreaming = Constants.enableStreamingDefault
	@AppStorage(WhisperaSettings.twoPassFinalizerKey) private var twoPassFinalizerRaw =
		TwoPassFinalizerMode.off.rawValue

	/// Falls back to `TranscriptionEngine.fresh` for the same reason
	/// `WhisperaSettings` does: a stored engine from a build that shipped one we
	/// no longer do must degrade, not trap.
	private var selectedEngine: TranscriptionEngine {
		TranscriptionEngine.stored(transcriptionEngineRaw)
	}

	// Discovery list for the backend engines (auto + whisperaStreaming). Empty
	// with no error means "not fetched yet"; a failed fetch keeps the pin row
	// visible so a stale pin stays clearable even when the backend is down.
	@State private var discoveredServers: [DictationServer] = []
	@State private var isFetchingServers = false
	@State private var serverFetchError: String?

	// Automatic engine: what it currently resolves to, refreshed whenever the
	// picker lands on it.
	@State private var autoResolutionCaption = "Deciding…"
	@State private var isResolvingAutoEngine = false

	private var usesBackendServers: Bool {
		selectedEngine == .auto || selectedEngine == .whisperaStreaming
	}

	var body: some View {
		Form {
			Section {
				enginePicker
				engineDescription
				if selectedEngine == .auto { autoCaption }
			} header: {
				Text("Speech")
			}

			if usesBackendServers {
				Section {
					backendServerConfig
				} header: {
					Text("Whispera server")
				}
			}

			if selectedEngine == .realtimeDirect || selectedEngine == .whisperViaBYOK {
				Section {
					ServerEntrySettingsView(capability: .speech)
				} header: {
					Text("Speech server")
				} footer: {
					Text("Any OpenAI-compatible speech-to-text server, such as speaches or whisper.cpp. The base URL ends in /v1.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			// `auto` is included alongside the server engines: it may resolve to
			// one, and the wording below is already engine-agnostic.
			if selectedEngine.streamsFromAServer || selectedEngine == .auto {
				Section {
					finalPassRow
				} footer: {
					Text(
						enableStreaming
							? "Live transcription is on, so words appear while you speak. Turning it off under General → Live Transcription Mode makes Whispera record first and transcribe at the end."
							: "Live Transcription Mode is off, so nothing appears until you stop speaking and the whole recording is transcribed. Turn it on under General to see words as you say them."
					)
					.font(.caption)
					.foregroundStyle(.secondary)
				}
			}

			Section {
				ServerEntrySettingsView(capability: .llm)
			} header: {
				Text("LLM server")
			} footer: {
				Text("Where recipes run, Clean up included. Any OpenAI-compatible server: a local runtime (ollama, llama-server, LM Studio) or a cloud with your own key.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Section {
				MacLinkSettingsSection()
			} header: {
				Text("Mac Link")
			}
		}
		.formStyle(.grouped)
	}

	@ViewBuilder
	private var engineDescription: some View {
		let text: String? =
			switch selectedEngine {
			case .auto: nil
			case .whisperaStreaming:
				"Streams audio to a Whispera transcription server over a WebSocket. Leave the server blank to use the backend's own default."
			case .realtimeDirect:
				"Streams audio straight to an OpenAI-Realtime engine, with no Whispera backend in between. The engine holds its own credentials, so use this only on a network you trust."
			case .whisperKit:
				"Runs entirely on this Mac with the model chosen under General → Whisper Model. No server and no network involved."
			case .whisperViaBYOK:
				"Uploads each finished recording to the speech server below and pastes what comes back. Any OpenAI-compatible transcription endpoint works — a cloud with your own key, or a server on your own network."
			}
		if let text {
			Text(LocalizedStringKey(text))
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}

	// MARK: - Final pass (two-pass dictation)

	/// Shown only for the engines that stream: the second pass polishes a
	/// streaming engine's low-latency draft, while the on-device engine already
	/// re-reads its whole buffer as it goes and has nothing to gain from one.
	private var finalPassRow: some View {
		Picker(selection: $twoPassFinalizerRaw) {
			ForEach(TwoPassFinalizerMode.allCases, id: \.rawValue) { mode in
				Text(mode.displayName).tag(mode.rawValue)
			}
		} label: {
			VStack(alignment: .leading, spacing: 2) {
				Text("Final pass")
				Text("More accurate paste, adds a short wait after you stop.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.accessibilityIdentifier("twoPassFinalizerPicker")
	}

	// MARK: - Engine picker

	private var enginePicker: some View {
		Picker(selection: engineSelection) {
			ForEach(TranscriptionEngine.allCases, id: \.rawValue) { engine in
				Text(engine.displayName).tag(engine.rawValue)
			}
		} label: {
			VStack(alignment: .leading, spacing: 2) {
				Text("Engine")
				Text("Where speech-to-text runs. On-device needs no network.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.accessibilityIdentifier("transcriptionEnginePicker")
	}

	/// Writes the engine and nothing else.
	///
	/// It used to turn Live Transcription Mode on whenever the chosen engine
	/// streamed from a server — a Settings picker mutating a global dictation
	/// mode, which is what made the app start behaving like a dictation session
	/// while the user was only trying to configure one (WHI-86). The info box
	/// above still explains the consequence; explaining is the settings window's
	/// job, switching is not.
	private var engineSelection: Binding<String> {
		Binding(
			get: { transcriptionEngineRaw },
			set: { WhisperaSettings.selectEngine(TranscriptionEngine.stored($0)) })
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
					"Server",
					text: $backendURL,
					prompt: Text(verbatim: WhisperaSettings.serverURLString)
				)
				.autocorrectionDisabled()
				.onSubmit { refreshDiscoveredServers() }
				.accessibilityIdentifier("transcriptionServerURLField")

				Button {
					refreshDiscoveredServers(explicit: true)
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
		// Cleared before anything can re-probe, so a warning never outlives the
		// URL it was about (WHI-86).
		.onChange(of: backendURL) { _, _ in
			serverFetchError = nil
			discoveredServers = []
		}
		// One task keyed on engine + URL. The sleep is cancelled by the next
		// keystroke, so only a pause of at least the debounce reaches the fetch.
		// It used to be 400 ms, which is inside normal typing cadence — the
		// backend field probed half-typed addresses too.
		.task(id: "\(transcriptionEngineRaw)|\(backendURL)") {
			try? await Task.sleep(for: .milliseconds(ServerProbePolicy.debounceMilliseconds))
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

	private func serverDetail(for server: DictationServer) -> String {
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

	/// `explicit` is the Refresh button, and it is the only caller that probes an
	/// address the automatic path would leave alone — pressing Refresh on a URL
	/// that cannot be reached should say so, which is exactly the case the
	/// automatic path must stay quiet about.
	private func refreshDiscoveredServers(explicit: Bool = false) {
		guard usesBackendServers else { return }
		guard explicit || WhisperaSettings.transcriptionBackendURL != nil else { return }
		isFetchingServers = true
		serverFetchError = nil
		Task { @MainActor in
			do {
				guard let baseURL = WhisperaSettings.transcriptionBackendURL else {
					throw StreamingTranscriberError.invalidServerURL
				}
				// The same credential the dictation socket uses; an empty token is
				// fine against a self-hosted backend that requires none.
				discoveredServers = try await discoverServers(
					baseURL: baseURL,
					credentials: BackendCredentials.shared,
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
}
