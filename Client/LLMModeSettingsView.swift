// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI

/// Settings tab to pick where recipe LLM steps run (Local / Subscription / BYOK)
/// and configure each mode. See WHI-39.
struct LLMModeSettingsView: View {
	@AppStorage("whisperaLLMMode") private var modeRaw = LLMMode.local.rawValue
	@State private var auth = AuthManager.shared

	private var mode: LLMMode { LLMMode(rawValue: modeRaw) ?? .local }

	var body: some View {
		ScrollView {
			VStack(spacing: 24) {
				SettingsSection("AI Mode") {
					Picker("Run recipe steps using", selection: $modeRaw) {
						ForEach(LLMMode.allCases, id: \.rawValue) { mode in
							Text(mode.displayName).tag(mode.rawValue)
						}
					}
					.pickerStyle(.segmented)
				}

				switch mode {
				case .local: LocalModeConfig()
				case .subscription: SubscriptionModeConfig(isSignedIn: auth.isSignedIn, name: auth.displayName)
				case .byok: ByokModeConfig()
				}

				TranscriptionEngineConfig()
			}
			.padding(20)
		}
		.task { await auth.refresh() }
	}
}

private struct TranscriptionEngineConfig: View {
	@AppStorage("whisperaTranscriptionEngine") private var engineRaw = TranscriptionEngine.whisperKit.rawValue

	private var engine: TranscriptionEngine { TranscriptionEngine(rawValue: engineRaw) ?? .whisperKit }

	var body: some View {
		SettingsSection("Transcription Engine") {
			VStack(alignment: .leading, spacing: 8) {
				Picker("Speech-to-text", selection: $engineRaw) {
					ForEach(TranscriptionEngine.allCases, id: \.rawValue) { engine in
						Text(engine.displayName).tag(engine.rawValue)
					}
				}
				.pickerStyle(.menu)

				Text(note(for: engine))
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}

	private func note(for engine: TranscriptionEngine) -> String {
		switch engine {
		case .whisperKit:
			return "On-device, private, no network. Default."
		case .whisperViaWhispera:
			return "Audio is uploaded to Whispera and transcribed with OpenAI Whisper. Requires sign-in."
		case .whisperViaBYOK:
			return "Audio is uploaded directly to OpenAI using your saved key. Requires a BYOK OpenAI key."
		}
	}
}

private struct LocalModeConfig: View {
	@AppStorage("whisperaLocalServerURL") private var serverURL = WhisperaSettings.defaultLocalServerURL
	@AppStorage("whisperaLocalModel") private var model = ""
	@State private var testResult: String?
	@State private var availableModels: [String] = []
	@State private var isLoadingModels = false

	/// Servers that implement the OpenAI `GET /models` endpoint get a picker;
	/// everything else falls back to typing the model id.
	@ViewBuilder private var modelField: some View {
		if availableModels.isEmpty {
			TextField("Model (e.g. llama3.2)", text: $model)
				.textFieldStyle(.roundedBorder)
				.autocorrectionDisabled()
		} else {
			Picker("Model", selection: $model) {
				if model.isEmpty || !availableModels.contains(model) {
					Text(model.isEmpty ? "Select a model" : model).tag(model)
				}
				ForEach(availableModels, id: \.self) { Text($0).tag($0) }
			}
			.labelsHidden()
		}
	}

	var body: some View {
		SettingsSection("Local Server") {
			VStack(alignment: .leading, spacing: 10) {
				Text(
					"On-device / local OpenAI-compatible server (ollama, llama-server, vLLM, LM Studio). No account, no network beyond your machine."
				)
				.font(.caption)
				.foregroundColor(.secondary)
				TextField("http://localhost:11434/v1", text: $serverURL)
					.textFieldStyle(.roundedBorder)
					.autocorrectionDisabled()

				modelField

				HStack {
					AsyncButton("Test") { await runTest() }
					AsyncButton(isLoadingModels ? "Loading…" : "Reload models") { await loadModels() }
						.disabled(isLoadingModels)
					if let testResult {
						Text(testResult)
							.font(.caption)
							.foregroundColor(testResult.hasPrefix("OK") ? .green : .red)
							.lineLimit(2)
					}
				}
			}
			// Re-query whenever the server URL changes, so pointing at a new
			// endpoint repopulates the picker without a manual reload.
			.task(id: serverURL) { await loadModels() }
		}
	}

	private func loadModels() async {
		isLoadingModels = true
		defer { isLoadingModels = false }
		availableModels = (try? await LocalLLMExecutor().listModels()) ?? []
	}

	private func runTest() async {
		testResult = nil
		do {
			let reply = try await LocalLLMExecutor().chat(
				system: nil, prompt: "Reply with the single word: OK", model: nil, maxTokens: 10)
			testResult = "OK — \(reply.prefix(40))"
		} catch {
			testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}
}

private struct SubscriptionModeConfig: View {
	let isSignedIn: Bool
	let name: String

	var body: some View {
		SettingsSection("Subscription") {
			VStack(alignment: .leading, spacing: 6) {
				if isSignedIn {
					Label("Signed in as \(name)", systemImage: "checkmark.seal.fill")
						.foregroundColor(.green)
				} else {
					Label("Not signed in", systemImage: "exclamationmark.triangle.fill")
						.foregroundColor(.orange)
					Text("Sign in from the Account tab to use Subscription mode.")
						.font(.caption)
						.foregroundColor(.secondary)
				}
				Text("Recipe steps run on Whispera's servers using our provider keys.")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}
}

private struct ByokModeConfig: View {
	@State private var openaiKey = ""
	@State private var anthropicKey = ""
	@State private var savedProviders: Set<ProviderId> = []
	@State private var status: String?

	var body: some View {
		SettingsSection("Bring Your Own Key") {
			VStack(alignment: .leading, spacing: 12) {
				Text(
					"Your provider keys stay in the macOS Keychain and are sent only as the X-Provider-Key header on recipe execution. Requires a (free) signed-in account for the backend pass-through."
				)
				.font(.caption)
				.foregroundColor(.secondary)

				keyRow(provider: .openai, placeholder: "sk-...", text: $openaiKey)
				keyRow(provider: .anthropic, placeholder: "sk-ant-...", text: $anthropicKey)

				if let status {
					Text(status).font(.caption).foregroundColor(.secondary)
				}
			}
		}
		.onAppear { savedProviders = (try? Set(ByokKeyStore.shared.providers())) ?? [] }
	}

	private func keyRow(provider: ProviderId, placeholder: String, text: Binding<String>) -> some View {
		HStack {
			Text(provider.displayName).frame(width: 80, alignment: .leading)
			if savedProviders.contains(provider) {
				Text("Saved").foregroundColor(.green).font(.caption)
				Spacer()
				Button("Remove") {
					try? ByokKeyStore.shared.delete(provider: provider)
					savedProviders.remove(provider)
					status = "\(provider.displayName) key removed."
				}
			} else {
				SecureField(placeholder, text: text)
					.textFieldStyle(.roundedBorder)
				Button("Save") {
					let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !value.isEmpty else { return }
					do {
						try ByokKeyStore.shared.save(provider: provider, key: value)
						savedProviders.insert(provider)
						text.wrappedValue = ""
						status = "\(provider.displayName) key saved to Keychain."
					} catch {
						status = error.localizedDescription
					}
				}
				.disabled(text.wrappedValue.isEmpty)
			}
		}
	}
}
