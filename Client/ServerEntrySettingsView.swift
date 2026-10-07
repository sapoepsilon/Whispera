// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI
import WhisperaOpenAI

/// One server, configured: preset, base URL, model, API key, and one status
/// line with a Test button. Rows for a grouped `Form` section, the same for the
/// speech and the LLM server because they are the same thing (WHI-91).
///
/// Probing rules are WHI-86's: typing is inert, Refresh is the only explicit
/// probe, an automatic fetch runs at most once per settled well-formed URL, and
/// an incomplete address gets a neutral hint rather than a warning.
struct ServerEntrySettingsView: View {
	let capability: ServerEntry.Capability

	@AppStorage private var urlString: String
	@AppStorage private var model: String

	@State private var apiKey = ""
	@State private var hasSavedKey = false
	@State private var keyError: String?

	@State private var modelOptions: [OpenAIModel] = []
	@State private var check: ServerCheck = .idle
	/// Bumped by Refresh and by a settled URL. Keying the probe task on it —
	/// rather than on the URL text — is what stops a keystroke starting one.
	@State private var probeToken = 0
	/// The last value a probe actually ran for, so a settled URL is fetched once
	/// and re-focusing the field does not re-fetch it.
	@State private var probedURL: String?

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

	private var id: String { capability.rawValue }

	var body: some View {
		Group {
			presetRow
			urlRow
			modelRow
			apiKeyRow
			statusRow
		}
		.animation(.easeInOut(duration: 0.2), value: check)
		.animation(.easeInOut(duration: 0.2), value: modelOptions)
		.onAppear { hasSavedKey = entry.hasKey }
		// The stale status goes the moment the field changes, before any new
		// probe can run.
		.onChange(of: urlString) { _, _ in
			check = .idle
			modelOptions = []
		}
		.task(id: urlString) {
			try? await Task.sleep(for: .milliseconds(ServerProbePolicy.debounceMilliseconds))
			guard !Task.isCancelled else { return }
			settled()
		}
		.onChange(of: urlFocused) { _, focused in
			if !focused { settled() }
		}
		.task(id: probeToken) {
			guard probeToken > 0 else { return }
			await refreshModels()
		}
	}

	// MARK: - Rows

	/// Picking a preset only fills the fields; "Custom" is whatever was typed.
	private var presetRow: some View {
		Picker("Preset", selection: presetSelection) {
			Text("Custom").tag("")
			ForEach(capability.presets) { preset in
				Text(preset.name).tag(preset.name)
			}
		}
		.accessibilityIdentifier("\(id)ServerPresetMenu")
	}

	private var presetSelection: Binding<String> {
		Binding(
			get: {
				let current = ServerURLNormalizer.normalize(urlString)
				return capability.presets.first { ServerURLNormalizer.normalize($0.urlString) == current }?.name ?? ""
			},
			set: { name in
				guard let preset = capability.presets.first(where: { $0.name == name }) else { return }
				urlString = preset.urlString
				if !preset.model.isEmpty { model = preset.model }
			})
	}

	private var urlRow: some View {
		VStack(alignment: .trailing, spacing: 4) {
			TextField("Base URL", text: $urlString, prompt: Text(verbatim: capability.placeholderURL))
				.autocorrectionDisabled()
				.focused($urlFocused)
				.onSubmit { settled() }
				.accessibilityIdentifier("\(id)ServerURLField")
			if let hint {
				HStack(spacing: 6) {
					Text(verbatim: hint.message)
						.font(.caption)
						.foregroundStyle(.secondary)
						.accessibilityIdentifier("\(id)ServerURLHint")
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
	}

	private var modelRow: some View {
		LabeledContent("Model") {
			HStack(spacing: 6) {
				if modelOptions.isEmpty {
					// Never listed, or the listing failed: a typed model keeps the
					// server usable even when it cannot be enumerated.
					TextField(
						"Model", text: $model, prompt: Text(verbatim: capability.placeholderModel)
					)
					.labelsHidden()
					.autocorrectionDisabled()
					.accessibilityIdentifier("\(id)ServerModelField")
				} else {
					Picker("Model", selection: $model) {
						if !modelOptions.contains(where: { $0.id == model }) {
							Text(verbatim: model.isEmpty ? "—" : model).tag(model)
						}
						ForEach(modelOptions, id: \.id) { option in
							Text(verbatim: option.id).tag(option.id)
						}
					}
					.labelsHidden()
					.accessibilityIdentifier("\(id)ServerModelPicker")
				}
				Button {
					// The only explicit probe; it runs even for a URL the automatic
					// fetch already tried, because "try again" is the point.
					probedURL = nil
					probeToken += 1
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.borderless)
				.disabled(check == .checking || !ServerProbePolicy.shouldProbe(urlString))
				.help(Text("Refresh the model list"))
				.accessibilityIdentifier("\(id)ServerRefreshButton")
			}
		}
	}

	/// Optional: a LAN engine usually wants no key, a cloud always does. Stored
	/// in the Keychain by server id, never in UserDefaults. A 401/403 is said
	/// here, next to the field that fixes it.
	private var apiKeyRow: some View {
		VStack(alignment: .trailing, spacing: 4) {
			LabeledContent("API key") {
				HStack(spacing: 8) {
					if hasSavedKey {
						Label("Saved in Keychain", systemImage: "key.fill")
							.foregroundStyle(.green)
							.accessibilityIdentifier("\(id)ServerKeySaved")
						Button("Remove") {
							try? OpenAIKeyStore.shared.delete(serverId: capability.keychainId)
							hasSavedKey = false
							keyError = nil
						}
						.accessibilityIdentifier("\(id)ServerRemoveKeyButton")
					} else {
						SecureField("API key", text: $apiKey, prompt: Text("Optional"))
							.labelsHidden()
							.onSubmit(saveKey)
							.accessibilityIdentifier("\(id)ServerKeyField")
						Button("Save", action: saveKey)
							.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
							.accessibilityIdentifier("\(id)ServerSaveKeyButton")
					}
				}
			}
			if let message = keyError ?? (check.isKeyProblem ? check.message : nil) {
				Label(message, systemImage: "key.slash")
					.font(.caption)
					.foregroundStyle(.red)
					.accessibilityIdentifier("\(id)ServerKeyProblem")
			}
		}
	}

	/// One line for everything else the server said, and the Test button.
	private var statusRow: some View {
		HStack(spacing: 8) {
			if check == .checking {
				ProgressView().controlSize(.small)
			} else if !check.isKeyProblem, let symbol {
				Image(systemName: symbol).foregroundStyle(toneColor)
			}
			if !check.isKeyProblem, let message = check.message {
				Text(message)
					.font(.caption)
					.foregroundStyle(check.tone == .neutral ? Color.secondary : toneColor)
					.lineLimit(3)
					.textSelection(.enabled)
					.accessibilityIdentifier("\(id)ServerStatus")
			}
			Spacer()
			Button("Test", action: runTest)
				.disabled(check == .checking || entry.url == nil)
				.accessibilityIdentifier("\(id)ServerTestButton")
		}
	}

	private var symbol: String? {
		switch check.tone {
		case .neutral: return nil
		case .success: return "checkmark.circle.fill"
		case .warning: return "exclamationmark.triangle.fill"
		case .failure: return "xmark.octagon.fill"
		}
	}

	private var toneColor: Color {
		switch check.tone {
		case .neutral: return .secondary
		case .success: return .green
		case .warning: return .orange
		case .failure: return .red
		}
	}

	// MARK: - Actions

	private func saveKey() {
		let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else { return }
		do {
			try OpenAIKeyStore.shared.save(serverId: capability.keychainId, key: value)
			hasSavedKey = true
			apiKey = ""
			keyError = nil
			if check.isKeyProblem { check = .idle }
		} catch {
			keyError = error.localizedDescription
		}
	}

	/// Called when the field settles — a pause, Enter, or losing focus. Does
	/// nothing unless the value is a URL worth a request and is not the one
	/// already probed.
	private func settled() {
		guard ServerProbePolicy.shouldProbe(urlString), probedURL != urlString else { return }
		probeToken += 1
	}

	private func client(for url: URL) -> OpenAICompatibleClient {
		OpenAICompatibleClient(baseURL: url, apiKeyProvider: entry.keyProvider, logger: .whispera)
	}

	private func refreshModels() async {
		let entry = self.entry
		guard let url = entry.url else { return }
		probedURL = entry.urlString
		// The moment the user has committed to a LAN address is the moment the
		// local-network prompt makes sense — and the only way to raise it at all,
		// since URLSession answers a missing grant with a bare -1009 instead.
		LocalNetworkPrimer.shared.prime(for: url)
		check = .checking
		do {
			// The speech side filters to models that can transcribe; the LLM side
			// takes whatever is offered — there is no task tag to filter on.
			let client = client(for: url)
			modelOptions =
				capability == .speech ? try await client.transcriptionModels() : try await client.models()
			if !modelOptions.isEmpty, !modelOptions.contains(where: { $0.id == model }) {
				model = modelOptions[0].id
			}
			check = .listed(count: modelOptions.count)
		} catch {
			modelOptions = []
			check = ServerCheck.classify(error, hasKey: entry.hasKey, destination: url)
		}
	}

	private func runTest() {
		let entry = self.entry
		guard let url = entry.url else { return }
		LocalNetworkPrimer.shared.prime(for: url)
		check = .checking
		Task {
			check = await ServerCheck.test(entry: entry, client: client(for: url))
		}
	}
}
