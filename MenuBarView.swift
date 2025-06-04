import SwiftUI

struct MenuBarView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject private var whisperKit = WhisperKitTranscriber.shared
    @AppStorage("globalShortcut") private var shortcutKey = "⌘⇧R"
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Mac Whisper")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 12) {
                HStack {
                    if audioManager.isTranscribing {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Transcribing...")
                            .foregroundColor(.blue)
                    } else {
                        Image(systemName: audioManager.isRecording ? "mic.fill" : "mic")
                            .foregroundColor(audioManager.isRecording ? .red : .primary)
                        Text(audioManager.isRecording ? "Recording..." : "Ready")
                            .foregroundColor(audioManager.isRecording ? .red : .secondary)
                    }
                }
                
                // Manual record button for testing
                Button(action: {
                    audioManager.toggleRecording()
                }) {
                    Text(audioManager.isRecording ? "Stop Recording" : "Start Recording")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(audioManager.isTranscribing)
                
                if let error = audioManager.transcriptionError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(3)
                        .padding(.horizontal)
                } else if let transcription = audioManager.lastTranscription {
                    Text(transcription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .padding(.horizontal)
                }
                
                Divider()
                
                // WhisperKit Status
                HStack {
                    Text("WhisperKit:")
                        .foregroundColor(.secondary)
                    Spacer()
                    if whisperKit.isInitialized {
                        Text("✅ Ready")
                            .foregroundColor(.green)
                    } else {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Loading...")
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                HStack {
                    Text("Shortcut:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(shortcutKey)
                        .font(.system(.body, design: .monospaced))
                }
                
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Text("Open Settings")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .onTapGesture {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                } else {
                    Button("Open Settings") {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button("Test Shortcut Detection") {
                    print("🧪 Manual shortcut test triggered")
                    audioManager.toggleRecording()
                }
                .buttonStyle(.borderless)
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(width: 300)
        .padding()
    }
}