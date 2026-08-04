// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI

/// Settings tab to pick where recipe LLM steps run (Local / BYOK) and configure
/// each mode. See WHI-39.
struct LLMModeSettingsView: View {
	@AppStorage("whisperaLLMMode") private var modeRaw = LLMMode.local.rawValue

	private var mode: LLMMode { LLMMode(rawValue: modeRaw) ?? .local }

	var body: some View {
		ScrollView {
			VStack(spacing: 24) {
				Picker("Run recipe steps using", selection: $modeRaw) {
					ForEach(LLMMode.allCases, id: \.rawValue) { mode in
						Text(mode.displayName).tag(mode.rawValue)
					}
				}
				.pickerStyle(.segmented)
				.frame(maxWidth: .infinity, alignment: .leading)

				switch mode {
				case .local: LocalModeConfig()
				case .byok: ByokModeConfig()
				}
			}
			.padding(20)
		}
		// A raw value the picker no longer offers would leave it with nothing
		// selected, so rewrite it to the fallback the router already uses.
		.onAppear { if LLMMode(rawValue: modeRaw) == nil { modeRaw = LLMMode.local.rawValue } }
	}
}

private struct LocalModeConfig: View {
	@AppStorage("whisperaLocalServerURL") private var serverURL = WhisperaSettings.defaultLocalServerURL
	@AppStorage("whisperaLocalModel") private var model = ""
	@State private var apiKey = ""
	@State private var hasSavedKey = false
	@State private var keyStatus: String?
	@State private var testResult: String?
	@State private var testing = false

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
				TextField("Model (e.g. llama3.2)", text: $model)
					.textFieldStyle(.roundedBorder)
					.autocorrectionDisabled()

				apiKeyRow
				if let keyStatus {
					Text(keyStatus).font(.caption).foregroundColor(.secondary)
				}

				HStack {
					Button("Test") { runTest() }
						.disabled(testing)
					if testing { ProgressView().scaleEffect(0.7) }
					if let testResult {
						Text(testResult)
							.font(.caption)
							.foregroundColor(testResult.hasPrefix("OK") ? .green : .red)
							.lineLimit(2)
					}
				}
			}
		}
		.onAppear { hasSavedKey = ByokKeyStore.shared.hasLocalServerKey() }
	}

	/// Optional bearer token — many local servers need none, proxies usually do.
	/// Stored in the Keychain, never in UserDefaults.
	private var apiKeyRow: some View {
		HStack {
			Text("API key").frame(width: 80, alignment: .leading)
			if hasSavedKey {
				Text("Saved").foregroundColor(.green).font(.caption)
				Spacer()
				Button("Remove") {
					try? ByokKeyStore.shared.deleteLocalServerKey()
					hasSavedKey = false
					keyStatus = "Local server key removed."
				}
			} else {
				SecureField("Optional", text: $apiKey)
					.textFieldStyle(.roundedBorder)
				Button("Save") {
					let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !value.isEmpty else { return }
					do {
						try ByokKeyStore.shared.saveLocalServerKey(value)
						hasSavedKey = true
						apiKey = ""
						keyStatus = "Local server key saved to Keychain."
					} catch {
						keyStatus = error.localizedDescription
					}
				}
				.disabled(apiKey.isEmpty)
			}
		}
	}

	private func runTest() {
		testing = true
		testResult = nil
		Task {
			defer { testing = false }
			do {
				let reply = try await LocalLLMExecutor().chat(
					system: nil, prompt: "Reply with the single word: OK", model: nil, maxTokens: 10)
				testResult = "OK — \(reply.prefix(40))"
			} catch {
				testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
			}
		}
	}
}

private struct ByokModeConfig: View {
	@AppStorage("whisperaByokModel") private var model = ""
	@State private var openaiKey = ""
	@State private var anthropicKey = ""
	@State private var savedProviders: Set<ProviderId> = []
	@State private var status: String?

	var body: some View {
		SettingsSection("Bring Your Own Key") {
			VStack(alignment: .leading, spacing: 12) {
				Text(
					"Your provider keys stay in the macOS Keychain and are sent straight to the provider when a recipe runs. No account, no Whispera server."
				)
				.font(.caption)
				.foregroundColor(.secondary)

				keyRow(provider: .openai, placeholder: "sk-...", text: $openaiKey)
				keyRow(provider: .anthropic, placeholder: "sk-ant-...", text: $anthropicKey)

				TextField("Model (default \(WhisperaSettings.defaultByokModel))", text: $model)
					.textFieldStyle(.roundedBorder)
					.autocorrectionDisabled()

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
