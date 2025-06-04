import SwiftUI

struct MenuBarView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject private var whisperKit = WhisperKitTranscriber.shared
		@AppStorage("globalShortcut") private var shortcutKey = "⌘⌥D"
    
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
                // Status card
                StatusCardView(
                    audioManager: audioManager,
                    whisperKit: whisperKit
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
                    HStack {
                        Text("Global Shortcut")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(shortcutKey)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
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
                        .onTapGesture {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    } else {
                        Button {
                            NSApp.activate(ignoringOtherApps: true)
                            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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
            // Start WhisperKit initialization when the menu bar view appears
            whisperKit.startInitialization()
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
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var whisperKit: WhisperKitTranscriber
    @AppStorage("selectedModel") private var selectedModel = "openai_whisper-small.en"
    
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
                    } else {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                // Current model display
                if whisperKit.isInitialized {
                    HStack {
                        Text(currentModelDisplayName)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundColor(.blue)
                        
                        Spacer()
                        
                        // Model size indicator
                        Text(currentModelSize)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    
    private var statusColor: Color {
        if audioManager.isTranscribing {
            return .blue
        } else if audioManager.isRecording {
            return .red
        } else {
            return .green
        }
    }
    
    private var statusIcon: Image {
        if audioManager.isTranscribing {
            return Image(systemName: "waveform")
        } else if audioManager.isRecording {
            return Image(systemName: "mic.fill")
        } else {
            return Image(systemName: "checkmark.circle.fill")
        }
    }
    
    private var statusTitle: String {
        if audioManager.isTranscribing {
            return "Transcribing..."
        } else if audioManager.isRecording {
            return "Recording..."
        } else {
            return "Ready"
        }
    }
    
    private var statusSubtitle: String {
        if audioManager.isTranscribing {
            return "Converting speech to text"
        } else if audioManager.isRecording {
            return "Listening for voice input"
        } else {
            return "Press shortcut to start recording"
        }
    }
    
    private var currentModelDisplayName: String {
        // Always show what WhisperKit is actually using, or fall back to settings
        let modelName = whisperKit.currentModel ?? selectedModel
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
            .font(.system(.body, design: .rounded))
            .foregroundColor(.primary)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
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
