// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI
import WhisperaOpenAI

/// One server, configured: base URL, optional key, model.
///
/// The same view for both capabilities, because they are the same thing. What
/// it replaces on the LLM side was a segmented Local/BYOK picker over two
/// different surfaces — Local had a URL, a model and an optional key, BYOK had
/// two fixed provider key rows and a model field with no URL at all — even
/// though both arms built the identical executor underneath. See WHI-91.
///
/// Probing rules are WHI-86's: typing is inert, Refresh is the only explicit
/// probe, an automatic fetch runs at most once per settled well-formed URL, and
/// an incomplete address gets a neutral hint rather than an orange warning.
struct ServerEntrySettingsView: View {
	let capability: ServerEntry.Capability

	@AppStorage private var urlString: String
	@AppStorage private var model: String

	@State private var apiKey = ""
	@State private var hasSavedKey = false
	@State private var keyStatus: String?

	@State private var modelOptions: [OpenAIModel] = []
	@State private var isFetchingModels = false
	@State private var fetchError: String?
	/// Bumped by Refresh and by a settled URL. Keying the probe task on it —
	/// rather than on the URL text — is what stops a keystroke starting one.
	@State private var probeToken = 0
	/// The last value a probe actually ran for, so a settled URL is fetched once
	/// and re-focusing the field does not re-fetch it.
	@State private var probedURL: String?

	@State private var testResult: String?
	@State private var testing = false

	@FocusState private var urlFocused: Bool

	init(capability: ServerEntry.Capability) {
		self.capability = capability
		self._urlString = AppStorage(wrappedValue: "", capability.urlKey)
		self._model = AppStorage(wrappedValue: "", capability.modelKey)
	}

	private var entry: ServerEntry {
		ServerEntry(capability: capability, urlString: urlString, model: model)
	}

	private var hint: ServerURLHint? { ServerURLNormalizer.hint(for: urlString) }

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			presetRow
			urlRow
			hintRow
			modelRow
			apiKeyRow
			if let keyStatus {
				Text(keyStatus).font(.caption).foregroundColor(.secondary)
			}
			if let fetchError {
				HStack(spacing: 6) {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundColor(.orange)
						.font(.caption)
					Text(fetchError).font(.caption).foregroundColor(.orange)
				}
				.transition(.opacity)
			}
			if capability == .llm { testRow }
		}
		.animation(.easeInOut(duration: 0.2), value: fetchError)
		.animation(.easeInOut(duration: 0.2), value: modelOptions)
		.onAppear { hasSavedKey = entry.hasKey }
		// Requirement 5: the stale error goes the moment the field changes, before
		// any new probe can run.
		.onChange(of: urlString) { _, _ in
			fetchError = nil
			modelOptions = []
		}
		// Requirement 1: the automatic probe waits for the field to settle. The
		// sleep is cancelled by the next keystroke because the task is keyed on
		// the text, so only a pause of at least the debounce reaches `probe()`.
		.task(id: urlString) {
			try? await Task.sleep(for: .milliseconds(ServerProbePolicy.debounceMilliseconds))
			guard !Task.isCancelled else { return }
			settled()
		}
		// Blur is the other way a value settles. Enter is `onSubmit` on the field.
		.onChange(of: urlFocused) { _, focused in
			if !focused { settled() }
		}
		.task(id: probeToken) {
			guard probeToken > 0 else { return }
			await refreshModels()
		}
	}

	// MARK: - Rows

	private var presetRow: some View {
		HStack(spacing: 8) {
			Text("Preset").frame(width: 80, alignment: .leading)
			Menu("Choose…") {
				ForEach(capability.presets) { preset in
					Button(preset.name) {
						urlString = preset.urlString
						if !preset.model.isEmpty { model = preset.model }
					}
				}
			}
			.frame(width: 160)
			.accessibilityIdentifier("\(capability.rawValue)ServerPresetMenu")
			Text("Fills in the address. Everything here is editable.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}

	private var urlRow: some View {
		HStack(spacing: 8) {
			Text("Base URL").frame(width: 80, alignment: .leading)
			TextField(capability.placeholderURL, text: $urlString)
				.textFieldStyle(.roundedBorder)
				.autocorrectionDisabled()
				.focused($urlFocused)
				.onSubmit { settled() }
				.accessibilityIdentifier("\(capability.rawValue)ServerURLField")

			Button {
				// The only explicit probe. It runs even when the URL is one the
				// automatic fetch already tried, because "try again" is the whole
				// point of the button.
				probedURL = nil
				probeToken += 1
			} label: {
				Image(systemName: "arrow.clockwise")
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
			.disabled(isFetchingModels || !ServerProbePolicy.shouldProbe(urlString))
			.accessibilityIdentifier("\(capability.rawValue)ServerRefreshButton")
			.help("Ask this server what models it has")
		}
	}

	/// Neutral, not alarming: this is the state an address is in while it is
	/// being typed, and it is the reason no request has gone out yet.
	@ViewBuilder
	private var hintRow: some View {
		if let hint {
			HStack(spacing: 6) {
				Text(hint.message)
					.font(.caption)
					.foregroundColor(.secondary)
					.accessibilityIdentifier("\(capability.rawValue)ServerURLHint")
				if hint == .needsPort {
					Button("Use :\(ServerURLNormalizer.defaultEnginePort)") {
						urlString = ServerURLNormalizer.withDefaultPort(urlString)
					}
					.buttonStyle(.link)
					.font(.caption)
				}
			}
		}
	}

	private var modelRow: some View {
		HStack(spacing: 8) {
			Text("Model").frame(width: 80, alignment: .leading)
			if isFetchingModels {
				ProgressView().scaleEffect(0.6)
				Text("Asking the server what it can run…")
					.font(.caption)
					.foregroundColor(.secondary)
			} else if !modelOptions.isEmpty {
				Picker("Model", selection: $model) {
					ForEach(modelOptions, id: \.id) { option in
						Text(option.id).tag(option.id)
					}
				}
				.labelsHidden()
				.frame(width: 260)
				.accessibilityIdentifier("\(capability.rawValue)ServerModelPicker")
			} else {
				// The listing never ran or it failed. Typing a model by hand keeps
				// the server usable even when it cannot be enumerated.
				TextField(capability.placeholderModel, text: $model)
					.textFieldStyle(.roundedBorder)
					.autocorrectionDisabled()
					.accessibilityIdentifier("\(capability.rawValue)ServerModelField")
			}
		}
	}

	/// Optional: a LAN engine usually wants no key, a cloud always does, and a
	/// proxy in front of either might. Stored in the Keychain by server id,
	/// never in UserDefaults.
	private var apiKeyRow: some View {
		HStack(spacing: 8) {
			Text("API key").frame(width: 80, alignment: .leading)
			if hasSavedKey {
				Text("Saved").foregroundColor(.green).font(.caption)
				Spacer()
				Button("Remove") {
					try? OpenAIKeyStore.shared.delete(serverId: capability.keychainId)
					hasSavedKey = false
					keyStatus = "Key removed."
				}
				.accessibilityIdentifier("\(capability.rawValue)ServerRemoveKeyButton")
			} else {
				SecureField("Optional", text: $apiKey)
					.textFieldStyle(.roundedBorder)
					.accessibilityIdentifier("\(capability.rawValue)ServerKeyField")
				Button("Save") {
					let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !value.isEmpty else { return }
					do {
						try OpenAIKeyStore.shared.save(serverId: capability.keychainId, key: value)
						hasSavedKey = true
						apiKey = ""
						keyStatus = "Key saved to the Keychain."
					} catch {
						keyStatus = error.localizedDescription
					}
				}
				.disabled(apiKey.isEmpty)
			}
		}
	}

	private var testRow: some View {
		HStack {
			Button("Test") { runTest() }
				.disabled(testing || entry.url == nil)
				.accessibilityIdentifier("llmServerTestButton")
			if testing { ProgressView().scaleEffect(0.7) }
			if let testResult {
				Text(testResult)
					.font(.caption)
					.foregroundColor(testResult.hasPrefix("OK") ? .green : .red)
					.lineLimit(2)
			}
		}
	}

	// MARK: - Probing

	/// Called when the field settles — a pause, Enter, or losing focus. Does
	/// nothing unless the value is a URL worth a request and is not the one
	/// already probed.
	private func settled() {
		guard ServerProbePolicy.shouldProbe(urlString), probedURL != urlString else { return }
		probeToken += 1
	}

	private func refreshModels() async {
		let entry = self.entry
		guard let url = entry.url else { return }
		probedURL = entry.urlString
		// The moment the user has committed to a LAN address is the moment the
		// local-network prompt makes sense — and the only way to raise it at all,
		// since URLSession answers a missing grant with a bare -1009 instead.
		// A no-op for loopback and for anything off the LAN. See WHI-67 QA.
		LocalNetworkPrimer.shared.prime(for: url)
		isFetchingModels = true
		fetchError = nil
		defer { isFetchingModels = false }

		let client = OpenAICompatibleClient(
			baseURL: url, apiKeyProvider: entry.keyProvider, logger: .whispera)
		do {
			// The speech side filters to models that can transcribe, the same way
			// the backend server list filters to realtime-capable servers. The LLM
			// side takes whatever is offered — there is no task tag to filter on.
			modelOptions =
				capability == .speech
				? try await client.transcriptionModels()
				: try await client.models()
			if !modelOptions.isEmpty, !modelOptions.contains(where: { $0.id == model }) {
				model = modelOptions[0].id
			}
		} catch {
			modelOptions = []
			let described = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
			fetchError =
				LocalNetworkAccess.advice(forFailure: described, destination: url.absoluteString)
				?? described
		}
	}

	private func runTest() {
		testing = true
		testResult = nil
		let entry = self.entry
		Task {
			defer { testing = false }
			guard let url = entry.url else {
				testResult = RecipeRouterError.noServerConfigured.errorDescription
				return
			}
			do {
				let reply = try await RecipeRouter.client(for: entry, url: url).complete(
					system: nil,
					prompt: "Reply with the single word: OK",
					model: entry.model,
					maxTokens: 10)
				testResult = "OK — \(reply.prefix(40))"
			} catch {
				testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
			}
		}
	}
}
