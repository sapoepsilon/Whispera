import SwiftUI

struct YouTubeURLInputView: View {
	@State private var viewModel: YouTubeTranscriptionViewModel
	@State private var showingExportDialog = false
	@FocusState private var isURLFieldFocused: Bool

	init(youtubeTranscriptionManager: YouTubeTranscriptionManager) {
		self._viewModel = State(
			initialValue: YouTubeTranscriptionViewModel(
				youtubeTranscriptionManager: youtubeTranscriptionManager))
	}

	var body: some View {
		VStack(spacing: 0) {
			// Header
			headerView

			Divider()

			// Main content
			ScrollView {
				VStack(spacing: 20) {
					// URL input section
					urlInputSection

					// Video info section
					if viewModel.videoInfo != nil || viewModel.isLoadingVideoInfo {
						videoInfoSection
					}

					// Segment selection (if video info is available)
					if viewModel.videoInfo != nil {
						segmentSelectionSection
					}

					// Transcription controls
					if viewModel.videoInfo != nil {
						transcriptionControlsSection
					}

					// Results section
					if !viewModel.transcriptionResult.isEmpty || !viewModel.transcriptionSegments.isEmpty {
						resultsSection
					}
				}
				.padding()
			}
		}
		.background(.regularMaterial)
		.fileExporter(
			isPresented: $showingExportDialog,
			document: TranscriptionDocument(content: exportContent),
			contentType: .plainText,
			defaultFilename: youtubeFilename
		) { result in
			handleExportResult(result)
		}
		.alert("YouTube Transcription Error", isPresented: $viewModel.showingError) {
			Button("OK") {
				viewModel.showingError = false
			}
			if viewModel.error != nil {
				Button("Retry") {
					viewModel.startTranscription()
					viewModel.showingError = false
				}
			}
		} message: {
			if let error = viewModel.error {
				VStack(alignment: .leading, spacing: 8) {
					Text(error.localizedDescription)
					if let suggestion = error.recoverySuggestion {
						Text(suggestion)
							.font(.caption)
					}
				}
			}
		}
	}

	// MARK: - Header View

	private var headerView: some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text("YouTube Transcription")
					.font(.headline)

				if viewModel.isTranscribing {
					Text("Transcribing video...")
						.font(.caption)
						.foregroundColor(.secondary)
				} else if !viewModel.transcriptionResult.isEmpty {
					Text("Transcription completed")
						.font(.caption)
						.foregroundColor(.green)
				}
			}

			Spacer()

			HStack(spacing: 12) {
				if viewModel.isTranscribing {
					Button("Cancel", systemImage: "stop.fill") {
						viewModel.cancelTranscription()
					}
					.buttonStyle(.bordered)
				}

				if !viewModel.transcriptionResult.isEmpty {
					Menu("Export", systemImage: "square.and.arrow.up") {
						Button("Copy to Clipboard") {
							viewModel.copyResultToClipboard()
						}

						Button("Export File") {
							showingExportDialog = true
						}
					}
					.menuStyle(.borderlessButton)
				}
			}
		}
		.padding()
	}

	// MARK: - URL Input Section

	private var urlInputSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("YouTube URL")
				.font(.headline)

			HStack {
				TextField("Enter YouTube URL...", text: $viewModel.inputURL)
					.textFieldStyle(.roundedBorder)
					.focused($isURLFieldFocused)
					.onSubmit {
						viewModel.validateAndLoadVideoInfo()
					}
					.onChange(of: viewModel.inputURL) { _, newValue in
						if newValue.isEmpty {
							viewModel.validateAndLoadVideoInfo()
						}
					}

				Button("Load", systemImage: "arrow.down.circle") {
					viewModel.validateAndLoadVideoInfo()
					isURLFieldFocused = false
				}
				.buttonStyle(.bordered)
				.disabled(!viewModel.isURLValid || viewModel.isLoadingVideoInfo)
			}

			if !viewModel.isURLValid && !viewModel.inputURL.isEmpty {
				Text("Please enter a valid YouTube URL")
					.font(.caption)
					.foregroundColor(.red)
			}
		}
	}

	// MARK: - Video Info Section

	private var videoInfoSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Video Information")
				.font(.headline)

			if viewModel.isLoadingVideoInfo {
				HStack {
					ProgressView()
						.scaleEffect(0.8)
					Text("Loading video information...")
						.font(.body)
						.foregroundColor(.secondary)
				}
				.padding()
			} else if let videoInfo = viewModel.videoInfo {
				VStack(alignment: .leading, spacing: 8) {
					HStack(alignment: .top, spacing: 12) {
						// Thumbnail (if available)
						if let thumbnailURL = videoInfo.thumbnailURL {
							AsyncImage(url: thumbnailURL) { image in
								image
									.resizable()
									.aspectRatio(contentMode: .fit)
							} placeholder: {
								Rectangle()
									.fill(.secondary.opacity(0.2))
									.overlay {
										Image(systemName: "photo")
											.foregroundColor(.secondary)
									}
							}
							.frame(width: 120, height: 68)
							.clipShape(RoundedRectangle(cornerRadius: 8))
						}

						VStack(alignment: .leading, spacing: 4) {
							Text(videoInfo.title)
								.font(.body)
								.fontWeight(.medium)
								.lineLimit(2)

							Text("Duration: \(formatDuration(videoInfo.duration))")
								.font(.caption)
								.foregroundColor(.secondary)

							Text("Video ID: \(videoInfo.videoID)")
								.font(.caption)
								.foregroundColor(.secondary)
						}

						Spacer()
					}
				}
				.padding()
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
			}
		}
	}

	// MARK: - Segment Selection Section

	private var segmentSelectionSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("Transcription Options")
					.font(.headline)

				Spacer()

				Toggle("Segment Mode", isOn: $viewModel.isSegmentMode)
					.toggleStyle(.switch)
			}

			if viewModel.isSegmentMode {
				VStack(alignment: .leading, spacing: 12) {
					Text("Select time range to transcribe:")
						.font(.subheadline)
						.foregroundColor(.secondary)

					HStack(spacing: 16) {
						VStack(alignment: .leading, spacing: 4) {
							Text("Start time")
								.font(.caption)
								.foregroundColor(.secondary)

							TextField("0:00", text: $viewModel.customStartTime)
								.textFieldStyle(.roundedBorder)
								.frame(width: 80)
								.onSubmit {
									viewModel.updateSegmentTimes()
								}
						}

						Text("to")
							.foregroundColor(.secondary)

						VStack(alignment: .leading, spacing: 4) {
							Text("End time")
								.font(.caption)
								.foregroundColor(.secondary)

							TextField("5:00", text: $viewModel.customEndTime)
								.textFieldStyle(.roundedBorder)
								.frame(width: 80)
								.onSubmit {
									viewModel.updateSegmentTimes()
								}
						}

						Spacer()

						if let videoInfo = viewModel.videoInfo {
							Text("Max: \(formatDuration(videoInfo.duration))")
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}

					if !viewModel.hasValidSegmentRange {
						Text("Invalid time range. Start time must be before end time.")
							.font(.caption)
							.foregroundColor(.red)
					}
				}
				.padding()
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
			}
		}
	}

	// MARK: - Transcription Controls Section

	private var transcriptionControlsSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Transcription Settings")
				.font(.headline)

			HStack {
				Text("Audio Quality:")
				Spacer()
				Menu(viewModel.currentQualityDisplayName) {
					ForEach(viewModel.qualityOptions, id: \.0) { option in
						Button(option.1) {
							// Quality selection would be handled by the view model
						}
					}
				}
				.frame(width: 150)
			}
		}
	}

	// MARK: - Results Section

	private var resultsSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("Transcription Result")
					.font(.headline)

				Spacer()

				if viewModel.isTranscribing {
					ProgressView()
						.scaleEffect(0.8)
				}
			}

			if viewModel.isTranscribing {
				VStack(alignment: .leading, spacing: 8) {
					ProgressView(value: viewModel.transcriptionProgress)
						.progressViewStyle(.linear)

					Text("Transcribing video... This may take a few minutes.")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			} else if viewModel.showTimestamps && !viewModel.transcriptionSegments.isEmpty {
				// Timestamped results
				ScrollView {
					VStack(alignment: .leading, spacing: 8) {
						ForEach(Array(viewModel.transcriptionSegments.enumerated()), id: \.offset) {
							_, segment in
							HStack(alignment: .top, spacing: 12) {
								Text(segment.formattedStartTime)
									.font(.caption.monospaced())
									.foregroundColor(.secondary)
									.frame(width: 50, alignment: .leading)

								Text(segment.text)
									.font(.body)
									.textSelection(.enabled)
							}
							.padding(.vertical, 2)
						}
					}
				}
				.frame(maxHeight: 300)
				.padding()
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
			} else if !viewModel.transcriptionResult.isEmpty {
				// Plain text results
				ScrollView {
					Text(viewModel.transcriptionResult)
						.font(.body)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(maxHeight: 300)
				.padding()
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
			}
		}
	}

	// MARK: - Helper Properties

	private var exportContent: String {
		var content = "# YouTube Transcription\n\n"

		if let videoInfo = viewModel.videoInfo {
			content += "**Video:** \(videoInfo.title)\n"
			content += "**Duration:** \(formatDuration(videoInfo.duration))\n"
			content += "**URL:** \(viewModel.inputURL)\n"
			content += "**Transcribed:** \(Date().formatted())\n\n"

			if viewModel.isSegmentMode {
				content +=
					"**Segment:** \(formatDuration(viewModel.selectedStartTime)) - \(formatDuration(viewModel.selectedEndTime))\n\n"
			}
		}

		content += "## Transcription\n\n"

		if viewModel.showTimestamps && !viewModel.transcriptionSegments.isEmpty {
			for segment in viewModel.transcriptionSegments {
				content += "[\(segment.formattedStartTime)] \(segment.text)\n\n"
			}
		} else {
			content += "\(viewModel.transcriptionResult)\n\n"
		}

		return content
	}

	private var youtubeFilename: String {
		if let videoInfo = viewModel.videoInfo {
			let sanitizedTitle = videoInfo.title.replacingOccurrences(
				of: "[^a-zA-Z0-9\\s]", with: "", options: .regularExpression)
			return "\(sanitizedTitle) - Transcription"
		}
		return "YouTube Transcription"
	}

	// MARK: - Event Handlers

	private func handleExportResult(_ result: Result<URL, Error>) {
		switch result {
		case .success(let url):
			print("Exported to: \(url)")
		case .failure(let error):
			print("Export failed: \(error)")
		}
	}

	// MARK: - Helper Functions

	private func formatDuration(_ seconds: Double) -> String {
		let hours = Int(seconds) / 3600
		let minutes = Int(seconds) % 3600 / 60
		let remainingSeconds = Int(seconds) % 60

		if hours > 0 {
			return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
		} else {
			return String(format: "%d:%02d", minutes, remainingSeconds)
		}
	}
}

// MARK: - Start Transcription Button

extension YouTubeURLInputView {
	private var startTranscriptionButton: some View {
		Button("Start Transcription", systemImage: "play.fill") {
			viewModel.startTranscription()
		}
		.buttonStyle(.borderedProminent)
		.disabled(!viewModel.canStartTranscription || !viewModel.hasValidSegmentRange)
		.frame(maxWidth: .infinity)
	}
}

#Preview {
	YouTubeURLInputView(
		youtubeTranscriptionManager: YouTubeTranscriptionManager(
			fileTranscriptionManager: FileTranscriptionManager(),
			networkDownloader: NetworkFileDownloader()
		)
	)
	.frame(width: 600, height: 500)
}
