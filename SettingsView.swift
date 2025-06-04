import SwiftUI

struct SettingsView: View {
    @AppStorage("globalShortcut") private var globalShortcut = "⌘⇧R"
    @AppStorage("selectedModel") private var selectedModel = "base"
    @AppStorage("autoDownloadModel") private var autoDownloadModel = true
    @AppStorage("soundFeedback") private var soundFeedback = true
    
    private let availableModels = ["tiny", "base", "small", "medium", "large"]
    
    var body: some View {
        TabView {
            GeneralSettingsView(
                globalShortcut: $globalShortcut,
                soundFeedback: $soundFeedback
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
            
            ModelSettingsView(
                selectedModel: $selectedModel,
                autoDownloadModel: $autoDownloadModel,
                availableModels: availableModels
            )
            .tabItem {
                Label("Model", systemImage: "cpu")
            }
        }
        .frame(width: 500, height: 300)
    }
}

struct GeneralSettingsView: View {
    @Binding var globalShortcut: String
    @Binding var soundFeedback: Bool
    @State private var isRecordingShortcut = false
    @State private var eventMonitor: Any?
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Global Shortcut:")
                        Spacer()
                        Button(action: {
                            if isRecordingShortcut {
                                stopRecording()
                            } else {
                                startRecording()
                            }
                        }) {
                            Text(isRecordingShortcut ? "Recording..." : globalShortcut)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(isRecordingShortcut ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isRecordingShortcut ? Color.blue : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if isRecordingShortcut {
                        Text("Press the desired key combination...")
                            .font(.caption)
                            .foregroundColor(.blue)
                    } else {
                        Text("Click to change shortcut")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Toggle("Sound Feedback", isOn: $soundFeedback)
                    .help("Play sound when starting/stopping recording")
                
                Button("Reset to Default") {
                    globalShortcut = "⌘⇧R"
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .onDisappear {
            stopRecording()
        }
    }
    
    private func startRecording() {
        isRecordingShortcut = true
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if isRecordingShortcut {
                let shortcut = formatKeyEvent(event)
                if !shortcut.isEmpty {
                    globalShortcut = shortcut
                    stopRecording()
                }
                return nil // Consume the event
            }
            return event
        }
    }
    
    private func stopRecording() {
        isRecordingShortcut = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    private func formatKeyEvent(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags
        
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.shift) { parts.append("⇧") }
        
        // Get the key character
        if let characters = event.charactersIgnoringModifiers?.uppercased() {
            parts.append(characters)
        }
        
        // Only accept combinations with at least one modifier
        return flags.intersection([.command, .option, .control, .shift]).isEmpty ? "" : parts.joined()
    }
}

struct ModelSettingsView: View {
    @Binding var selectedModel: String
    @Binding var autoDownloadModel: Bool
    let availableModels: [String]
    @ObservedObject private var whisperKit = WhisperKitTranscriber.shared
    
    var body: some View {
        Form {
            Section("WhisperKit Models") {
                HStack {
                    Text("Status:")
                    Spacer()
                    if whisperKit.isInitialized {
                        Text("✅ Ready")
                            .foregroundColor(.green)
                    } else {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Initializing...")
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                if whisperKit.isInitialized {
                    Picker("Current Model:", selection: $selectedModel) {
                        ForEach(whisperKit.availableModels, id: \.self) { model in
                            Text(model.replacingOccurrences(of: "openai_whisper-", with: "").capitalized)
                                .tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { newModel in
                        Task {
                            try? await whisperKit.switchModel(to: newModel)
                        }
                    }
                    
                    HStack {
                        Text("Current Model:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(whisperKit.currentModel?.replacingOccurrences(of: "openai_whisper-", with: "") ?? "None")
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    Text("Waiting for WhisperKit to initialize...")
                        .foregroundColor(.secondary)
                }
                
                Toggle("Automatic model selection", isOn: $autoDownloadModel)
                    .help("Automatically select the best model for your Mac")
            }
            
            Section("Legacy Model Manager") {
                Text("The old whisper.cpp model downloads are no longer needed with WhisperKit")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding()
    }
}