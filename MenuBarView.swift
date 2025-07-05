import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var audioManager: AudioManager
	var whisperKit = WhisperKitTranscriber.shared
	@AppStorage("globalShortcut") private var shortcutKey = "⌘⌥D"
	@AppStorage("globalCommandShortcut") private var commandShortcutKey = "⌘⌥C"
    @AppStorage("enableTranslation") private var enableTranslation = false
    
    // MARK: - Injected Dependencies
    @State var permissionManager: PermissionManager
    @State var updateManager: UpdateManager

    var body: some View {
        VStack(spacing: 0) {
            // Header with app icon and title - following design language
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                
                Text("Whispera")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
            
            // Main content
            VStack(spacing: 16) {
                // Update notification banner (if available)
                if let latestVersion = updateManager.latestVersion,
                   AppVersion(latestVersion) > AppVersion.current {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                            Text("Update Available")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                            Spacer()
                        }
                        
                        HStack {
                            Text("Whispera \(latestVersion)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            if updateManager.isUpdateDownloaded {
                                Button("Install") {
                                    Task {
                                        try? await updateManager.installDownloadedUpdate()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            } else {
                                Button("Update") {
                                    Task {
                                        try? await updateManager.downloadUpdate()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                    .padding(8)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.blue.opacity(0.3), lineWidth: 1)
                    )
                }
                
                // Status card
                StatusCardView(
                    audioManager: audioManager,
                    whisperKit: whisperKit,
                    permissionManager: permissionManager
                )
                
                // Controls
                VStack(spacing: 12) {
                    // Primary action button - enhanced with design language
                    Button(action: {
                        audioManager.toggleRecording()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: buttonIcon)
                            Text(buttonText)
                                .font(.system(.body, design: .rounded, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .buttonStyle(PrimaryButtonStyle(isRecording: isActiveState))
                    .disabled(audioManager.isTranscribing)
                    
                    // Shortcut display - design language compliant
                    VStack(spacing: 8) {
                        HStack {
                            Text(enableTranslation ? "Translation" : "Transcription")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(shortcutKey)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                Divider()
                
                // Secondary actions
                VStack(spacing: 8) {
                    if #available(macOS 14.0, *) {
                        SettingsLink {
                            Label("Settings", systemImage: "gear")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded {
                            // Set app policy to regular to ensure proper window focus
                            NSApp.setActivationPolicy(.regular)
                            NSApp.activate(ignoringOtherApps: true)
                            
                            // Bring the settings window to front after a brief delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") || $0.title.contains("Preferences") }) {
                                    settingsWindow.makeKeyAndOrderFront(nil)
                                    settingsWindow.orderFrontRegardless()
                                    NSApp.activate(ignoringOtherApps: true)
                                }
                            }
                        })
                    } else {
                        Button {
                            // Set app policy to regular to ensure proper window focus
                            NSApp.setActivationPolicy(.regular)
                            NSApp.activate(ignoringOtherApps: true)
                            
                            // Use legacy preferences approach
                            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                            
                            // Bring the settings window to front after a brief delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") || $0.title.contains("Preferences") }) {
                                    settingsWindow.makeKeyAndOrderFront(nil)
                                    settingsWindow.orderFrontRegardless()
                                    NSApp.activate(ignoringOtherApps: true)
                                }
                            }
                        } label: {
                            Label("Settings", systemImage: "gear")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    
                    Button("Quit Whispera") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(TertiaryButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            
            // Transcription result
            if let error = audioManager.transcriptionError {
                ErrorBannerView(error: error)
            } else if let transcription = audioManager.lastTranscription {
                TranscriptionResultView(text: transcription)
            }
		
        }
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // WhisperKit initialization is handled by AudioManager
        }
    }
    
    // MARK: - UI Helpers
    
    private var isActiveState: Bool {
        return audioManager.isRecording
    }
    
	private var buttonIcon: String {
        if audioManager.isRecording {
            return "stop.fill"
        } else {
            return "mic.fill"
        }
    }
    
    private var buttonText: String {
        if audioManager.isRecording {
            return "Stop Recording"
        } else {
            return "Start Recording"
        }
    }
}

// MARK: - Status Card
struct StatusCardView: View {
    @Bindable var audioManager: AudioManager
    var whisperKit: WhisperKitTranscriber
    var permissionManager: PermissionManager
    @AppStorage("selectedModel") private var selectedModel = ""
	@AppStorage("selectedLanguage") private var selectedLanguage = Constants.defaultLanguageName

    var body: some View {
        VStack(spacing: 12) {
            // Main status section
            HStack(spacing: 12) {
                // Status icon with design language colors
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    statusIcon
                        .font(.system(size: 20))
                        .foregroundColor(statusColor)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Permission status section
            if permissionManager.needsPermissions {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                        
                        Text("Permissions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(permissionManager.missingPermissionsDescription)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // AI Model section with current model display
            VStack(spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(whisperKit.isInitialized ? .green : .orange)
                            .frame(width: 8, height: 8)
                        
                        Text("Whisper Model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if whisperKit.isInitialized {
                        Text("Ready")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if whisperKit.isInitializing {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Loading...")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            
                            // Progress bar
                            ProgressView(value: whisperKit.initializationProgress)
                                .frame(width: 80)
                                .scaleEffect(0.8)
                            
                            // Status text
                            Text(whisperKit.initializationStatus)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Starting...")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                // Current model display or download progress
                if whisperKit.isDownloadingModel {
                    VStack(spacing: 4) {
                        HStack {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                Text("Downloading \(whisperKit.downloadingModelName ?? "model")...")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            Spacer()
                        }
                        
                        ProgressView(value: whisperKit.downloadProgress)
                            .frame(height: 4)
                    }
                } else if whisperKit.isInitialized {
                    HStack {
                        Text(currentModelDisplayName)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundColor(.blue)
                        
                        Spacer()

                        // Translation toggle
                        Button(action: {
                            audioManager.enableTranslation.toggle()
                            print("🟠 StatusCardView - Translation toggled to: \(audioManager.enableTranslation)")
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: audioManager.enableTranslation ? "arrow.right" : "doc.text")
                                    .font(.system(size: 8))
								Text(audioManager.enableTranslation ? "\(Constants.languageCode(for: selectedLanguage))" : "TXT")
                                    .font(.system(.caption2, design: .rounded, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(audioManager.enableTranslation ? .orange.opacity(0.2) : .gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundColor(audioManager.enableTranslation ? .orange : .secondary)
                        }
                        .buttonStyle(.plain)
                        
                        // Model size indicator
                        Text(currentModelSize)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.2).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    
    private var statusColor: Color {
        return StatusCardView.getStatusColor(
            isRecording: audioManager.isRecording,
            isTranscribing: audioManager.isTranscribing,
            isDownloading: whisperKit.isDownloadingModel,
            needsPermissions: permissionManager.needsPermissions
        )
    }
    
    private var statusIcon: Image {
        return StatusCardView.getStatusIcon(
            isRecording: audioManager.isRecording,
            isTranscribing: audioManager.isTranscribing,
            isDownloading: whisperKit.isDownloadingModel,
            needsPermissions: permissionManager.needsPermissions
        )
    }
    
    // MARK: - Reusable Status Functions
    
    static func getStatusColor(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, needsPermissions: Bool = false) -> Color {
        if needsPermissions {
            return .orange
        } else if isDownloading {
            return .orange
        } else if isTranscribing {
            return .blue
        } else if isRecording {
            return .red
        } else {
            return .green
        }
    }
    
    static func getStatusIcon(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, needsPermissions: Bool = false) -> Image {
        if needsPermissions {
            return Image(systemName: "exclamationmark.triangle.fill")
        } else if isDownloading {
            return Image(systemName: "arrow.down.circle.fill")
        } else if isTranscribing {
            return Image(systemName: "waveform")
        } else if isRecording {
            return Image(systemName: "mic.fill")
        } else {
            return Image(systemName: "checkmark.circle.fill")
        }
    }
    
    static func getStatusTitle(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, downloadingModel: String? = nil, enableTranslation: Bool = false, needsPermissions: Bool = false) -> String {
        if needsPermissions {
            return "Permissions Required"
        } else if isDownloading {
            return "Downloading Model..."
        } else if isTranscribing {
            return enableTranslation ? "Translating..." : "Transcribing..."
        } else if isRecording {
            return "Recording..."
        } else {
            return "Ready"
        }
    }
    
    static func getStatusSubtitle(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, downloadingModel: String? = nil, enableTranslation: Bool = false, needsPermissions: Bool = false) -> String {
        if needsPermissions {
            return "Grant required permissions to continue"
        } else if isDownloading {
            if let model = downloadingModel {
                let cleanName = model.replacingOccurrences(of: "openai_whisper-", with: "")
                return "Installing \(cleanName) model"
            } else {
                return "Installing Whisper model"
            }
        } else if isTranscribing {
            return enableTranslation ? "Converting speech to English" : "Converting speech to text"
        } else if isRecording {
            return "Listening for voice input"
        } else {
            return "Press shortcut to start recording"
        }
    }
    
    private var statusTitle: String {
        return StatusCardView.getStatusTitle(
            isRecording: audioManager.isRecording,
            isTranscribing: audioManager.isTranscribing,
            isDownloading: whisperKit.isDownloadingModel,
            downloadingModel: whisperKit.downloadingModelName,
            enableTranslation: audioManager.enableTranslation,
            needsPermissions: permissionManager.needsPermissions
        )
    }
    
    private var statusSubtitle: String {
        return StatusCardView.getStatusSubtitle(
            isRecording: audioManager.isRecording,
            isTranscribing: audioManager.isTranscribing,
            isDownloading: whisperKit.isDownloadingModel,
            downloadingModel: whisperKit.downloadingModelName,
            enableTranslation: audioManager.enableTranslation,
            needsPermissions: permissionManager.needsPermissions
        )
    }
    
    private var currentModelDisplayName: String {
        // Always show what WhisperKit is actually using, or fall back to settings
        let modelName = whisperKit.currentModel ?? selectedModel
        if modelName.isEmpty {
            return "No Model"
        }
        let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")
        
        switch cleanName {
        case "tiny.en": return "Tiny (English)"
        case "tiny": return "Tiny (Multilingual)"
        case "base.en": return "Base (English)"
        case "base": return "Base (Multilingual)"
        case "small.en": return "Small (English)"
        case "small": return "Small (Multilingual)"
        case "medium.en": return "Medium (English)"
        case "medium": return "Medium (Multilingual)"
        case "large-v2": return "Large v2"
        case "large-v3": return "Large v3"
        case "large-v3-turbo": return "Large v3 Turbo"
        case "distil-large-v2": return "Distil Large v2"
        case "distil-large-v3": return "Distil Large v3"
        default: return cleanName.capitalized
        }
    }
    
    private var currentModelSize: String {
        // Always show what WhisperKit is actually using, or fall back to settings
        let modelName = whisperKit.currentModel ?? selectedModel
        if modelName.isEmpty {
            return "—"
        }
        let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")
        
        switch cleanName {
        case "tiny.en", "tiny": return "39MB"
        case "base.en", "base": return "74MB"
        case "small.en", "small": return "244MB"
        case "medium.en", "medium": return "769MB"
        case "large-v2", "large-v3": return "1.5GB"
        case "large-v3-turbo": return "809MB"
        case "distil-large-v2", "distil-large-v3": return "756MB"
        default: return "Unknown"
        }
    }
}

// MARK: - Transcription Result
struct TranscriptionResultView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
            
            Text(text)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.blue.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}


// MARK: - Error Banner
struct ErrorBannerView: View {
    let error: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(2)
            
            Spacer()
        }
        .padding(12)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.red.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - Button Styles
struct PrimaryButtonStyle: ButtonStyle {
    let isRecording: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
			.padding(10)
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isRecording ? .red : .blue)
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
                    .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
			.padding(10)
            .font(.system(.body, design: .rounded))
            .foregroundColor(.primary)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .opacity(configuration.isPressed ? 0.7 : 1.0)
                    .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct TertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: .rounded))
            .foregroundColor(.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Command Approval View
struct CommandApprovalView: View {
    let command: String
    let userRequest: String
    let onApprove: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Command Approval Required")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            // User request
            if !userRequest.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Request:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(userRequest)
                        .font(.body)
                        .padding(8)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            
            // Generated command
            VStack(alignment: .leading, spacing: 4) {
                Text("Generated Command:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Execute") {
                    onApprove()
                }
                .buttonStyle(PrimaryButtonStyle(isRecording: false))
                
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - Clarification View
struct ClarificationView: View {
    let question: String
    let originalRequest: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    
    @State private var response: String = ""
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.blue)
                Text("Clarification Needed")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            // Original request
            if !originalRequest.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original Request:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(originalRequest)
                        .font(.body)
                        .padding(8)
                        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            
            // Clarification question
            VStack(alignment: .leading, spacing: 4) {
                Text("Question:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(question)
                    .font(.body)
                    .padding(8)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            
            // Response input
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Response:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $response)
                    .frame(height: 60)
                    .padding(8)
                    .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Submit") {
                    onSubmit(response)
                    response = ""
                }
                .buttonStyle(PrimaryButtonStyle(isRecording: false))
                .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                Button("Cancel") {
                    onCancel()
                    response = ""
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}
