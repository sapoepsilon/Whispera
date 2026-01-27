import SwiftUI
import UniformTypeIdentifiers

struct BenchmarkView: View {
	@StateObject private var runner = BenchmarkRunner()
	@State private var selectedFiles: [URL] = []
	@State private var summary: BenchmarkSummary?
	@State private var showingFilePicker = false
	@State private var showingExportSheet = false

	private let transcriber = WhisperKitTranscriber.shared

	var body: some View {
		ScrollView {
			VStack(spacing: 20) {
				headerSection
				modelInfoSection
				fileSelectionSection
				if runner.isRunning {
					progressSection
				}
				if !runner.results.isEmpty {
					resultsSection
				}
				if let summary = summary {
					summarySection(summary)
				}
				if let error = runner.error {
					errorSection(error)
				}
				historySection
			}
			.padding()
		}
		.frame(minWidth: 500, minHeight: 400)
		.fileImporter(
			isPresented: $showingFilePicker,
			allowedContentTypes: [.audio, .movie],
			allowsMultipleSelection: true
		) { result in
			switch result {
			case .success(let urls):
				selectedFiles = urls
			case .failure(let error):
				runner.error = error.localizedDescription
			}
		}
	}

	private var headerSection: some View {
		VStack(spacing: 8) {
			Text("RTF Benchmark")
				.font(.title)
				.fontWeight(.bold)
			Text("Measure Real-Time Factor for transcription performance")
				.font(.subheadline)
				.foregroundColor(.secondary)
		}
	}

	private var modelInfoSection: some View {
		GroupBox("Current Model") {
			HStack {
				if let model = transcriber.currentModel {
					Label(WhisperKitTranscriber.getModelDisplayName(for: model), systemImage: "cpu")
					Spacer()
					if transcriber.isCurrentModelLoaded() {
						Text("Ready")
							.foregroundColor(.green)
					} else {
						Text("Not Loaded")
							.foregroundColor(.orange)
					}
				} else {
					Text("No model loaded")
						.foregroundColor(.secondary)
				}
			}
			.padding(.vertical, 4)
		}
	}

	private var fileSelectionSection: some View {
		GroupBox("Audio Files") {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Button(action: { showingFilePicker = true }) {
						Label("Select Files", systemImage: "folder.badge.plus")
					}
					.disabled(runner.isRunning)

					Spacer()

					if !selectedFiles.isEmpty {
						Text("\(selectedFiles.count) file(s) selected")
							.foregroundColor(.secondary)

						Button(action: { selectedFiles.removeAll() }) {
							Image(systemName: "xmark.circle.fill")
								.foregroundColor(.secondary)
						}
						.buttonStyle(.plain)
						.disabled(runner.isRunning)
					}
				}

				if !selectedFiles.isEmpty {
					ScrollView(.horizontal, showsIndicators: false) {
						HStack(spacing: 8) {
							ForEach(selectedFiles, id: \.self) { url in
								FileChip(url: url) {
									selectedFiles.removeAll { $0 == url }
								}
								.disabled(runner.isRunning)
							}
						}
					}
				}

				Button(action: runBenchmark) {
					HStack {
						if runner.isRunning {
							ProgressView()
								.scaleEffect(0.8)
								.padding(.trailing, 4)
							Text("Running...")
						} else {
							Image(systemName: "play.fill")
							Text("Run Benchmark")
						}
					}
					.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.disabled(selectedFiles.isEmpty || runner.isRunning || !transcriber.isCurrentModelLoaded())
			}
			.padding(.vertical, 4)
		}
	}

	private var progressSection: some View {
		GroupBox("Progress") {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text("Processing:")
					Text(runner.currentFile)
						.fontWeight(.medium)
				}
				ProgressView(value: runner.currentProgress)
				Text("\(Int(runner.currentProgress * 100))%")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.padding(.vertical, 4)
		}
	}

	private var resultsSection: some View {
		GroupBox("Results") {
			ScrollView {
				VStack(alignment: .leading, spacing: 8) {
					ForEach(runner.results) { result in
						ResultRow(result: result)
						if result.id != runner.results.last?.id {
							Divider()
						}
					}
				}
			}
			.frame(maxHeight: 200)
		}
	}

	private func summarySection(_ summary: BenchmarkSummary) -> some View {
		GroupBox("Summary") {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					VStack(alignment: .leading) {
						Text("Average RTF")
							.font(.caption)
							.foregroundColor(.secondary)
						Text(summary.formattedAverageRTF)
							.font(.title)
							.fontWeight(.bold)
							.foregroundColor(summary.averageRTF <= 1.0 ? .green : .orange)
					}
					Spacer()
					VStack(alignment: .trailing) {
						Text("Total Audio")
							.font(.caption)
							.foregroundColor(.secondary)
						Text(formatDuration(summary.totalAudioDuration))
							.font(.title3)
					}
				}

				HStack {
					VStack(alignment: .leading) {
						Text("Min RTF")
							.font(.caption)
							.foregroundColor(.secondary)
						Text(String(format: "%.3fx", summary.minRTF))
							.fontWeight(.medium)
					}
					Spacer()
					VStack(alignment: .center) {
						Text("Max RTF")
							.font(.caption)
							.foregroundColor(.secondary)
						Text(String(format: "%.3fx", summary.maxRTF))
							.fontWeight(.medium)
					}
					Spacer()
					VStack(alignment: .trailing) {
						Text("Files")
							.font(.caption)
							.foregroundColor(.secondary)
						Text("\(summary.fileCount)")
							.fontWeight(.medium)
					}
				}

				HStack {
					Button(action: { saveBenchmark(summary) }) {
						Label("Save", systemImage: "square.and.arrow.down")
					}
					.buttonStyle(.borderedProminent)
					Button(action: { copyReport(summary) }) {
						Label("Copy Report", systemImage: "doc.on.doc")
					}
					Button(action: { exportJSON(summary) }) {
						Label("Show in Finder", systemImage: "folder")
					}
				}
			}
			.padding(.vertical, 4)
		}
	}

	private var historySection: some View {
		GroupBox("Benchmark History") {
			if runner.savedBenchmarks.isEmpty {
				Text("No saved benchmarks yet")
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 8)
			} else {
				ScrollView {
					VStack(alignment: .leading, spacing: 8) {
						ForEach(Array(runner.savedBenchmarks.enumerated()), id: \.offset) { index, saved in
							SavedBenchmarkRow(summary: saved) {
								runner.deleteBenchmark(at: index)
							}
							if index < runner.savedBenchmarks.count - 1 {
								Divider()
							}
						}
					}
				}
				.frame(maxHeight: 150)
			}
		}
	}

	private func errorSection(_ error: String) -> some View {
		GroupBox {
			HStack {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundColor(.red)
				Text(error)
					.foregroundColor(.red)
			}
		}
	}

	private func runBenchmark() {
		Task {
			summary = await runner.runBenchmark(audioFiles: selectedFiles)
		}
	}

	private func saveBenchmark(_ summary: BenchmarkSummary) {
		_ = runner.saveBenchmark(summary)
	}

	private func copyReport(_ summary: BenchmarkSummary) {
		let report = runner.generateReport(summary: summary)
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(report, forType: .string)
	}

	private func exportJSON(_ summary: BenchmarkSummary) {
		if let url = runner.exportResults(summary: summary) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		}
	}

	private func formatDuration(_ seconds: Double) -> String {
		if seconds < 60 {
			return String(format: "%.1fs", seconds)
		} else if seconds < 3600 {
			let minutes = Int(seconds) / 60
			let secs = Int(seconds) % 60
			return "\(minutes)m \(secs)s"
		} else {
			let hours = Int(seconds) / 3600
			let minutes = (Int(seconds) % 3600) / 60
			return "\(hours)h \(minutes)m"
		}
	}
}

struct FileChip: View {
	let url: URL
	let onRemove: () -> Void

	var body: some View {
		HStack(spacing: 4) {
			Image(systemName: "waveform")
				.font(.caption)
			Text(url.lastPathComponent)
				.font(.caption)
				.lineLimit(1)
			Button(action: onRemove) {
				Image(systemName: "xmark.circle.fill")
					.font(.caption)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.background(Color.secondary.opacity(0.2))
		.cornerRadius(12)
	}
}

struct ResultRow: View {
	let result: BenchmarkResult
	@State private var isExpanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				VStack(alignment: .leading) {
					Text(result.audioFileName)
						.fontWeight(.medium)
					Text("\(formatDuration(result.audioDurationSeconds)) audio")
						.font(.caption)
						.foregroundColor(.secondary)
				}
				Spacer()
				VStack(alignment: .trailing) {
					Text(result.formattedRTF)
						.fontWeight(.bold)
						.foregroundColor(result.isRealTime ? .green : .orange)
					Text(result.speedDescription)
						.font(.caption)
						.foregroundColor(.secondary)
				}
				Button(action: { withAnimation { isExpanded.toggle() } }) {
					Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
			}

			if isExpanded {
				VStack(alignment: .leading, spacing: 4) {
					Text("Transcription:")
						.font(.caption)
						.foregroundColor(.secondary)
					Text(result.transcribedText.isEmpty ? "No speech detected" : result.transcribedText)
						.font(.system(.caption, design: .monospaced))
						.padding(8)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(Color.secondary.opacity(0.1))
						.cornerRadius(6)
					HStack {
						Text("\(result.transcribedText.split(separator: " ").count) words")
							.font(.caption2)
							.foregroundColor(.secondary)
						Spacer()
						Button(action: { copyTranscription(result.transcribedText) }) {
							Label("Copy", systemImage: "doc.on.doc")
								.font(.caption2)
						}
						.buttonStyle(.plain)
					}
				}
				.transition(.opacity.combined(with: .move(edge: .top)))
			}
		}
	}

	private func formatDuration(_ seconds: Double) -> String {
		if seconds < 60 {
			return String(format: "%.1fs", seconds)
		} else {
			let minutes = Int(seconds) / 60
			let secs = Int(seconds) % 60
			return "\(minutes)m \(secs)s"
		}
	}

	private func copyTranscription(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}

struct SavedBenchmarkRow: View {
	let summary: BenchmarkSummary
	let onDelete: () -> Void

	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text(summary.modelName)
					.fontWeight(.medium)
				Text("\(summary.fileCount) files • \(formatDuration(summary.totalAudioDuration)) total")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			Spacer()
			VStack(alignment: .trailing, spacing: 2) {
				Text(summary.formattedAverageRTF)
					.fontWeight(.bold)
					.foregroundColor(summary.averageRTF <= 1.0 ? .green : .orange)
				Text("avg RTF")
					.font(.caption2)
					.foregroundColor(.secondary)
			}
			Button(action: onDelete) {
				Image(systemName: "trash")
					.foregroundColor(.red)
			}
			.buttonStyle(.plain)
		}
	}

	private func formatDuration(_ seconds: Double) -> String {
		if seconds < 60 {
			return String(format: "%.1fs", seconds)
		} else if seconds < 3600 {
			let minutes = Int(seconds) / 60
			return "\(minutes)m"
		} else {
			let hours = Int(seconds) / 3600
			let minutes = (Int(seconds) % 3600) / 60
			return "\(hours)h \(minutes)m"
		}
	}
}

#Preview {
	BenchmarkView()
		.frame(width: 600, height: 700)
}
