import Hub
//
//  ModelSelectionView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import SwiftUI

struct ModelSelectionStepView: View {
	@Binding var selectedModel: String
	@Bindable var audioManager: AudioManager

	@State private var availableModels: [String] = []
	@State private var isLoadingModels = false
	@State private var loadingError: String?
	@State private var errorMessage: String?
	@State private var showingError = false

	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 16) {
				Image(systemName: "brain.head.profile")
					.font(.system(size: 48))
					.foregroundColor(.blue)

				Text("Choose Whisper Model")
					.font(.system(.title, design: .rounded, weight: .semibold))

				Text(
					"Select the Whisper model that best fits your needs. You can change this later in Settings."
				)
				.font(.body)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
			}

			VStack(spacing: 16) {
				HStack {
					Text("AI Model")
						.font(.headline)
					Spacer()

					if isLoadingModels || audioManager.whisperKitTranscriber.isModelLoading {
						HStack(spacing: 8) {
							ProgressView()
								.scaleEffect(0.8)
							Text(getModelStatusText())
								.font(.caption)
								.foregroundColor(.secondary)
						}
					} else {
						VStack(alignment: .trailing, spacing: 4) {
							Picker("Model", selection: $selectedModel) {
								ForEach(getModelOptions(), id: \.0) { model in
									Text(model.1).tag(model.0)
								}
							}
							.frame(minWidth: 220)

							if needsModelLoad {
								Button("Load Model") {
									Task {
										do {
											try await audioManager.whisperKitTranscriber
												.switchModel(to: selectedModel)
										} catch {
											await MainActor.run {
												errorMessage =
													"Failed to load model: \(error.localizedDescription)"
												showingError = true
											}
										}
									}
								}
								.buttonStyle(.borderedProminent)
								.controlSize(.small)
							}
						}
					}
				}

				Text(
					"Choose your Whisper model: base is fast and accurate for most use cases, small provides better accuracy for complex speech, and tiny is fastest for simple transcriptions."
				)
				.font(.caption)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.leading)

				if let error = loadingError {
					Text("Error loading models: \(error)")
						.font(.caption)
						.foregroundColor(.red)
						.multilineTextAlignment(.center)
				}

				if audioManager.whisperKitTranscriber.isDownloadingModel {
					VStack(spacing: 8) {
						HStack(spacing: 8) {
							ProgressView()
								.scaleEffect(0.8)
							Text(
								"Downloading \(audioManager.whisperKitTranscriber.downloadingModelName ?? "model")..."
							)
							.font(.caption)
							.foregroundColor(.blue)
						}

						ProgressView(value: audioManager.whisperKitTranscriber.downloadProgress)
							.frame(height: 4)
					}
					.padding()
					.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
				}

				Text(
					"Models are downloaded once and stored locally. Your voice data never leaves your Mac."
				)
				.font(.caption)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
			}
		}
		.onAppear {
			loadAvailableModels()
		}
		.onChange(of: selectedModel) { _, newModel in
			downloadModelIfNeeded(newModel)
		}
		.alert("Error", isPresented: $showingError) {
			Button("OK") {
				showingError = false
				errorMessage = nil
			}
		} message: {
			Text(errorMessage ?? "An unknown error occurred")
		}
	}

	private var needsModelLoad: Bool {
		guard !selectedModel.isEmpty else { return false }
		guard audioManager.whisperKitTranscriber.isInitialized else { return false }
		guard
			!audioManager.whisperKitTranscriber.isDownloadingModel
				&& !audioManager.whisperKitTranscriber.isModelLoading
		else { return false }

		// Check if selected model is different from currently loaded model
		return selectedModel != audioManager.whisperKitTranscriber.currentModel
	}

	private func getModelStatusText() -> String {
		if isLoadingModels {
			return "Loading models..."
		} else if audioManager.whisperKitTranscriber.isModelLoading {
			return "Loading \(selectedModel)..."
		}
		return ""
	}

	private func getModelOptions() -> [(String, String)] {
		if availableModels.isEmpty {
			return [("loading", "Loading models...")]
		}

		return availableModels.compactMap { model in
			let displayName = WhisperKitTranscriber.getModelDisplayName(for: model)
			return (model, displayName)
		}
	}

	private func loadAvailableModels() {
		isLoadingModels = true
		loadingError = nil

		Task {
			do {
				// Use WhisperKitTranscriber to fetch available models
				try await audioManager.whisperKitTranscriber.refreshAvailableModels()
				let fetchedModels = audioManager.whisperKitTranscriber.availableModels

				await MainActor.run {
					self.availableModels = fetchedModels.sorted { lhs, rhs in
						WhisperKitTranscriber.getModelPriority(for: lhs)
							< WhisperKitTranscriber.getModelPriority(for: rhs)
					}
					self.isLoadingModels = false

					// Set default selection if none set or invalid
					if selectedModel.isEmpty || !fetchedModels.contains(selectedModel) {
						// Find the first small multilingual model (preferred) or fallback to first available
						if let smallModel = fetchedModels.first(where: {
							$0.contains("small") && !$0.contains(".en")
						}) {
							selectedModel = smallModel
						} else if let firstModel = fetchedModels.first {
							selectedModel = firstModel
						} else {
							selectedModel = "openai_whisper-small"
						}
					}
				}
			} catch {
				await MainActor.run {
					self.loadingError = error.localizedDescription
					self.errorMessage = "Failed to load available models: \(error.localizedDescription)"
					self.showingError = true
					self.isLoadingModels = false
					// Use fallback models
					self.availableModels = [
						"openai_whisper-tiny.en",
						"openai_whisper-base.en",
						"openai_whisper-small.en",
					]
					if selectedModel.isEmpty {
						if let smallModel = self.availableModels.first(where: {
							$0.contains("small") && !$0.contains(".en")
						}) {
							selectedModel = smallModel
						} else if let firstModel = self.availableModels.first {
							selectedModel = firstModel
						} else {
							selectedModel = "openai_whisper-small"
						}
					}
				}
			}
		}
	}

	private func downloadModelIfNeeded(_ modelId: String) {
		// Only download if not already downloaded and not currently downloading
		guard
			!audioManager.whisperKitTranscriber.downloadedModels.contains(modelId)
				&& !audioManager.whisperKitTranscriber.isDownloadingModel
		else {
			return  // Already downloaded or downloading
		}

		Task {
			do {
				try await audioManager.whisperKitTranscriber.downloadModel(modelId)
			} catch {
				await MainActor.run {
					loadingError = "Failed to download model: \(error.localizedDescription)"
					errorMessage = "Failed to download model: \(error.localizedDescription)"
					showingError = true
				}
			}
		}
	}
}
