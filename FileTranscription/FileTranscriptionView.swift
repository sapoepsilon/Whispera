import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @State private var viewModel: FileTranscriptionViewModel
    @State private var showingFilePicker = false
    @State private var showingExportDialog = false
    @State private var selectedResult: FileTranscriptionResult?
    
    init(fileTranscriptionManager: FileTranscriptionManager) {
        self._viewModel = State(initialValue: FileTranscriptionViewModel(fileTranscriptionManager: fileTranscriptionManager))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            if viewModel.selectedFiles.isEmpty && viewModel.transcriptionResults.isEmpty {
                emptyStateView
            } else {
                contentView
            }
        }
        .background(.regularMaterial)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }
        .fileExporter(
            isPresented: $showingExportDialog,
            document: TranscriptionDocument(content: exportContent),
            contentType: .plainText,
            defaultFilename: "Transcription Results"
        ) { result in
            handleExportResult(result)
        }
        .alert("Transcription Error", isPresented: $viewModel.showingError) {
            Button("OK") {
                viewModel.showingError = false
            }
            if viewModel.error != nil {
                Button("Retry") {
                    viewModel.retryFailedTranscriptions()
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
                Text("File Transcription")
                    .font(.headline)
                
                if viewModel.isTranscribing, let currentFile = viewModel.currentFileName {
                    Text("Transcribing: \(currentFile)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !viewModel.transcriptionResults.isEmpty {
                    let completed = viewModel.transcriptionResults.filter { $0.status == .completed }.count
                    let total = viewModel.transcriptionResults.count
                    Text("\(completed)/\(total) completed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Add Files", systemImage: "plus") {
                    showingFilePicker = true
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isTranscribing)
                
                if !viewModel.selectedFiles.isEmpty {
                    Button("Start", systemImage: "play.fill") {
                        viewModel.startTranscription()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isTranscribing)
                }
                
                if viewModel.isTranscribing {
                    Button("Cancel", systemImage: "stop.fill") {
                        viewModel.cancelTranscription()
                    }
                    .buttonStyle(.bordered)
                }
                
                if !viewModel.transcriptionResults.isEmpty {
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("Export All Results") {
                            showingExportDialog = true
                        }
                        
                        Button("Clear All") {
                            viewModel.clearAllFiles()
                        }
                        
                        if viewModel.transcriptionResults.contains(where: { $0.status == .failed }) {
                            Button("Retry Failed") {
                                viewModel.retryFailedTranscriptions()
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
        .padding()
    }
    
    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "doc.on.doc")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("No Files Selected")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Add audio or video files to start transcription")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                Button("Select Files", systemImage: "folder") {
                    showingFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Text("or drag and drop files here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }
    
    // MARK: - Content View
    
    private var contentView: some View {
        VStack(spacing: 0) {
            // Progress bar
            if viewModel.isTranscribing {
                ProgressView(value: viewModel.overallProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            
            // File list
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Pending files
                    if !viewModel.selectedFiles.isEmpty {
                        ForEach(Array(viewModel.selectedFiles.enumerated()), id: \.offset) { index, fileURL in
                            FileRowView(
                                filename: fileURL.lastPathComponent,
                                status: .pending,
                                onRemove: {
                                    viewModel.removeFile(at: index)
                                }
                            )
                        }
                    }
                    
                    // Transcription results
                    ForEach(viewModel.transcriptionResults) { result in
                        FileTranscriptionResultRowView(
                            result: result,
                            onView: {
                                selectedResult = result
                            },
                            onRetry: {
                                if result.status == .failed {
                                    viewModel.addFiles([result.fileURL])
                                    viewModel.startTranscription()
                                }
                            }
                        )
                    }
                }
                .padding()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .sheet(item: $selectedResult) { result in
            FileTranscriptionResultDetailView(result: result)
        }
    }
    
    // MARK: - Helper Properties
    
    private var allowedContentTypes: [UTType] {
        [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff]
    }
    
    private var exportContent: String {
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("export.txt")
            try viewModel.exportResults(to: tempURL)
            return try String(contentsOf: tempURL)
        } catch {
            return "Error generating export content: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Event Handlers
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            viewModel.addFiles(urls)
        case .failure(let error):
            print("File selection failed: \(error)")
        }
    }
    
    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            print("Exported to: \(url)")
        case .failure(let error):
            print("Export failed: \(error)")
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let urls = providers.compactMap { provider -> URL? in
            var url: URL?
            let semaphore = DispatchSemaphore(value: 0)
            
            _ = provider.loadObject(ofClass: URL.self) { loadedURL, _ in
                url = loadedURL
                semaphore.signal()
            }
            
            semaphore.wait()
            return url
        }
        
        if !urls.isEmpty {
            viewModel.addFiles(urls)
            return true
        }
        
        return false
    }
}

// MARK: - Supporting Views

struct FileRowView: View {
    let filename: String
    let status: TranscriptionStatus
    let onRemove: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: status.icon)
                .foregroundColor(status.color)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.body)
                    .lineLimit(1)
                
                Text(status.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if status == .pending {
                Button("Remove", systemImage: "trash") {
                    onRemove()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            } else if status == .inProgress {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FileTranscriptionResultRowView: View {
    let result: FileTranscriptionResult
    let onView: () -> Void
    let onRetry: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: result.status.icon)
                .foregroundColor(result.status.color)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(result.filename)
                    .font(.body)
                    .lineLimit(1)
                
                HStack {
                    Text(result.status.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if result.duration > 0 {
                        Text("• \(String(format: "%.1fs", result.duration))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                if result.status == .completed {
                    Button("View", systemImage: "eye") {
                        onView()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if result.status == .failed {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        onRetry()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FileTranscriptionResultDetailView: View {
    let result: FileTranscriptionResult
    @Environment(\.dismiss) private var dismiss
    @State private var showingExport = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header info
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.filename)
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        HStack {
                            Label(result.status.displayName, systemImage: result.status.icon)
                                .foregroundColor(result.status.color)
                            
                            Spacer()
                            
                            if result.duration > 0 {
                                Text("Completed in \(String(format: "%.1fs", result.duration))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Transcription content
                    if result.status == .completed {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Transcription")
                                .font(.headline)
                            
                            if let segments = result.segments, !segments.isEmpty {
                                // Timestamped view
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                        HStack(alignment: .top) {
                                            Text(segment.formattedStartTime)
                                                .font(.caption.monospaced())
                                                .foregroundColor(.secondary)
                                                .frame(width: 50, alignment: .leading)
                                            
                                            Text(segment.text)
                                                .font(.body)
                                        }
                                    }
                                }
                            } else {
                                // Plain text view
                                Text(result.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                    } else if result.status == .failed, let error = result.error {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Error")
                                .font(.headline)
                                .foregroundColor(.red)
                            
                            Text(error.localizedDescription)
                                .font(.body)
                            
                            if let suggestion = error.recoverySuggestion {
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Transcription Result")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                if result.status == .completed {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Share", systemImage: "square.and.arrow.up") {
                            Button("Copy Text") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(result.text, forType: .string)
                            }
                            
                            Button("Export File") {
                                showingExport = true
                            }
                        }
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $showingExport,
            document: TranscriptionDocument(content: result.text),
            contentType: .plainText,
            defaultFilename: "\(result.filename) - Transcription"
        ) { _ in }
    }
}

// MARK: - Document Type

struct TranscriptionDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    
    var content: String
    
    init(content: String) {
        self.content = content
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        content = string
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8)!
        return .init(regularFileWithContents: data)
    }
}

#Preview {
    FileTranscriptionView(fileTranscriptionManager: FileTranscriptionManager())
        .frame(width: 600, height: 400)
}
