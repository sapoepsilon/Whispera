import SwiftUI
import AVFoundation
import WhisperKit

struct SettingsView: View {
    @AppStorage("globalShortcut") private var globalShortcut = "⌘⌥D"
    @AppStorage("selectedModel") private var selectedModel = ""
    @AppStorage("autoDownloadModel") private var autoDownloadModel = true
    @AppStorage("soundFeedback") private var soundFeedback = true
    @AppStorage("startSound") private var startSound = "Tink"
    @AppStorage("stopSound") private var stopSound = "Pop"
    @AppStorage("launchAtStartup") private var launchAtStartup = false
    @AppStorage("enableTranslation") private var enableTranslation = false
    @AppStorage("selectedLanguage") private var selectedLanguage = Constants.defaultLanguageName
    @ObservedObject private var whisperKit = WhisperKitTranscriber.shared
    @State private var availableModels: [String] = []
    @State private var isRecordingShortcut = false
    @State private var eventMonitor: Any?
    @State private var errorMessage: String?
    @State private var showingError = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 16) {
                HStack {
                    Text("Global Shortcut")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        if isRecordingShortcut {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    }) {
                        Text(isRecordingShortcut ? "Press keys..." : globalShortcut)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(isRecordingShortcut ? .red : .primary)
                }
                
                HStack {
                    Text("Sound Feedback")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $soundFeedback)
                }
                
                if soundFeedback {
                    HStack {
                        Picker("Start Sound", selection: $startSound) {
                            ForEach(getAvailableSounds(), id: \.self) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .frame(minWidth: 120)
                        .onChange(of: startSound) { _ in
                            previewSound(startSound)
                        }
                    }
                    
                    HStack {
                        Picker("Stop Sound", selection: $stopSound) {
                            ForEach(getAvailableSounds(), id: \.self) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .frame(minWidth: 120)
                        .onChange(of: stopSound) { _ in
                            previewSound(stopSound)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        
                        if whisperKit.isDownloadingModel || whisperKit.isModelLoading {
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text(getModelStatusText())
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                                
                                if whisperKit.isDownloadingModel {
                                    ProgressView(value: whisperKit.downloadProgress)
                                        .frame(width: 120, height: 4)
                                }
                            }
                        } else {
                            VStack(alignment: .trailing, spacing: 4) {
                                Picker("Whisper Model", selection: $selectedModel) {
                                    ForEach(getModelOptions(), id: \.0) { model in
                                        Text(model.1).tag(model.0)
                                    }
                                }
                                .frame(minWidth: 180)
                                
								if whisperKit.whisperKit?.modelState == .unloaded {
                                    Button("Load Model") {
                                        Task {
											do {
												try await whisperKit.whisperKit?.loadModels()
											} catch {
												await MainActor.run {
													errorMessage = "Failed to load model: \(error.localizedDescription)"
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
                    
                    // Show current model status
                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(getCurrentModelStatusText())
                            .font(.caption)
                            .foregroundColor(getModelStatusColor())
                    }
                }
                
                Text("Choose your Whisper model: base is fast and accurate for most use cases, small provides better accuracy for complex speech, and tiny is fastest for simple transcriptions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
                
                HStack {
                    Text("Auto Download")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $autoDownloadModel)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Translation Mode")
                            .font(.headline)
                        Text("Translate speech to English instead of transcribing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $enableTranslation)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Source Language")
                                .font(.headline)
                            Text("Language of the audio to transcribe")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("Language", selection: $selectedLanguage) {
                            ForEach(Constants.sortedLanguageNames, id: \.self) { language in
                                Text(language.capitalized).tag(language)
                            }
                        }
                        .frame(minWidth: 120)
                    }
                }
                
                HStack {
                    Text("Launch at Startup")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $launchAtStartup)
                }
                
                Divider()
                
                HStack {
                    Text("Setup")
                        .font(.headline)
                    Spacer()
                    Button("Show Onboarding Again") {
                        showOnboardingAgain()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            
            if needsPermissions {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Required Permissions")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    if !microphonePermissionGranted {
                        Text("• Microphone access required")
                            .font(.caption)
                    }
                    
                    if !accessibilityPermissionGranted {
                        Text("• Accessibility access required")
                            .font(.caption)
                    }
                    
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
            }
            
            Spacer()
        }
        .frame(width: 400, height: 450)
        .background(.regularMaterial)
        .onAppear {
            loadAvailableModels()
            checkLaunchAtStartupStatus()
        }
        .onDisappear {
            stopRecording()
        }
        .onChange(of: selectedModel) { newModel in
            // Only auto-switch if auto-download is enabled
            if autoDownloadModel {
                Task {
                    await switchToModel(newModel)
                }
            }
        }
        .onChange(of: launchAtStartup) { newValue in
            setLaunchAtStartup(newValue)
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

    
    private var needsPermissions: Bool {
        !microphonePermissionGranted || !accessibilityPermissionGranted
    }
    
    private var microphonePermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    private var accessibilityPermissionGranted: Bool {
        AXIsProcessTrusted()
    }
    
    private func getModelOptions() -> [(String, String)] {
        if availableModels.isEmpty {
			availableModels = whisperKit.getRecommendedModels().supported
            return [("loading", "Loading models...")]
        }
        
        return availableModels.compactMap { model in
            let cleanName = model.replacingOccurrences(of: "openai_whisper-", with: "")
            let displayName: String
            
            switch cleanName {
            case "tiny.en": displayName = "Tiny (English) - 39MB"
            case "tiny": displayName = "Tiny (Multilingual) - 39MB"
            case "base.en": displayName = "Base (English) - 74MB"
            case "base": displayName = "Base (Multilingual) - 74MB"
            case "small.en": displayName = "Small (English) - 244MB"
            case "small": displayName = "Small (Multilingual) - 244MB"
            case "medium.en": displayName = "Medium (English) - 769MB"
            case "medium": displayName = "Medium (Multilingual) - 769MB"
            case "large-v2": displayName = "Large v2 (Multilingual) - 1.5GB"
            case "large-v3": displayName = "Large v3 (Multilingual) - 1.5GB"
            case "large-v3-turbo": displayName = "Large v3 Turbo (Multilingual) - 809MB"
            case "distil-large-v2": displayName = "Distil Large v2 (Multilingual) - 756MB"
            case "distil-large-v3": displayName = "Distil Large v3 (Multilingual) - 756MB"
            default: displayName = cleanName.capitalized
            }
            
            return (model, displayName)
        }
    }
    
    private func loadAvailableModels() {
        guard whisperKit.isInitialized else { return }
        
        Task {
            do {
                let recommendedModels = whisperKit.getRecommendedModels()
                try await whisperKit.refreshAvailableModels()
                let remoteModels = whisperKit.availableModels
                let downloaded = try await whisperKit.getDownloadedModels()
                
                // Use Set to automatically handle duplicates
                var allModelsSet = Set<String>()
                allModelsSet.insert(recommendedModels.default)
                allModelsSet.formUnion(recommendedModels.supported)
                allModelsSet.formUnion(remoteModels)
                
                var allModels = Array(allModelsSet)
                
                allModels.sort { (lhs, rhs) in
                    let lhsDownloaded = downloaded.contains(lhs)
                    let rhsDownloaded = downloaded.contains(rhs)
                    
                    if lhsDownloaded != rhsDownloaded {
                        return lhsDownloaded && !rhsDownloaded
                    }
                    
                    return getModelPriority(lhs) < getModelPriority(rhs)
                }
                
                await MainActor.run {
                    self.availableModels = allModels
                    
                    // Set default selection if none set or invalid
                    if selectedModel.isEmpty || !allModels.contains(selectedModel) {
                        // Find the first base model (preferred) or fallback to first available
                        if let baseModel = allModels.first(where: { $0.contains("base.en") }) {
                            selectedModel = baseModel
                        } else if let firstModel = allModels.first {
                            selectedModel = firstModel
                        }
                    }
                }
            } catch {
                print("Failed to load models: \(error)")
                await MainActor.run {
                    errorMessage = "Failed to load available models: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }
    
    private func getModelPriority(_ modelName: String) -> Int {
        let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")
        switch cleanName {
        case "tiny.en", "tiny": return 1
        case "base.en", "base": return 2
        case "small.en", "small": return 3
        case "medium.en", "medium": return 4
        case "large-v2": return 5
        case "large-v3": return 6
        case "large-v3-turbo": return 7
        case "distil-large-v2", "distil-large-v3": return 8
        default: return 9
        }
    }
    
    private func startRecording() {
        isRecordingShortcut = true
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if self.isRecordingShortcut {
                let shortcut = self.formatKeyEvent(event)
                if !shortcut.isEmpty {
                    self.globalShortcut = shortcut
                    self.stopRecording()
                }
                return nil
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
        
        if let characters = event.charactersIgnoringModifiers?.uppercased() {
            parts.append(characters)
        }
        
        return flags.intersection([.command, .option, .control, .shift]).isEmpty ? "" : parts.joined()
    }
    
    private func switchToModel(_ modelName: String) async {
        do {
            try await whisperKit.switchModel(to: modelName)
            print("✅ Successfully switched to model: \(modelName)")
        } catch {
            print("❌ Failed to switch to model \(modelName): \(error)")
            await MainActor.run {
                errorMessage = "Failed to switch to model \(modelName): \(error.localizedDescription)"
                showingError = true
            }
        }
    }
    
    private func getAvailableSounds() -> [String] {
        return [
            "None",
            "Basso",
            "Blow",
            "Bottle",
            "Frog",
            "Funk",
            "Glass",
            "Hero",
            "Morse",
            "Ping",
            "Pop",
            "Purr",
            "Sosumi",
            "Submarine",
            "Tink"
        ]
    }
    
    private func setLaunchAtStartup(_ enabled: Bool) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            print("❌ Could not get bundle identifier")
            return
        }
        
        let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(bundleIdentifier).plist")
        
        if enabled {
            // Create launch agent plist
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(bundleIdentifier)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(Bundle.main.executablePath ?? "")</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            
            do {
                // Create LaunchAgents directory if it doesn't exist
                try FileManager.default.createDirectory(
                    at: launchAgentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                
                // Write the plist file
                try plistContent.write(to: launchAgentURL, atomically: true, encoding: .utf8)
                print("✅ Launch at startup enabled")
            } catch {
                print("❌ Failed to enable launch at startup: \(error)")
            }
        } else {
            // Remove launch agent plist
            do {
                try FileManager.default.removeItem(at: launchAgentURL)
                print("✅ Launch at startup disabled")
            } catch {
                print("❌ Failed to disable launch at startup: \(error)")
            }
        }
    }
    
    private func previewSound(_ soundName: String) {
        guard soundName != "None" else { return }
        NSSound(named: soundName)?.play()
    }
    
    private func checkLaunchAtStartupStatus() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        
        let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(bundleIdentifier).plist")
        
        launchAtStartup = FileManager.default.fileExists(atPath: launchAgentURL.path)
    }
    
    private func showOnboardingAgain() {
        // Reset the onboarding completion flag
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        
        // Post notification to show onboarding
        NotificationCenter.default.post(name: NSNotification.Name("ShowOnboarding"), object: nil)
        
    }
    
    private func getModelStatusText() -> String {
        if whisperKit.isDownloadingModel {
            return "Downloading \(whisperKit.downloadingModelName ?? "model")..."
        } else if whisperKit.isModelLoading {
            return "Loading \(selectedModel)..."
        }
        return ""
    }
    
    private func getCurrentModelStatusText() -> String {
        if whisperKit.isDownloadingModel {
            return "Downloading..."
        } else if whisperKit.isModelLoading {
            return "Loading..."
        } else if whisperKit.isModelLoaded {
            if let currentModel = whisperKit.currentModel {
                let cleanName = currentModel.replacingOccurrences(of: "openai_whisper-", with: "")
                return "Loaded: \(cleanName)"
            } else {
                return "Model loaded"
            }
        } else if whisperKit.isInitialized {
			return whisperKit.whisperKit?.modelState == .unloaded ? "Different model selected" : "No model loaded"
        } else {
            return "Initializing..."
        }
    }
    
    private func getModelStatusColor() -> Color {
        if whisperKit.isDownloadingModel || whisperKit.isModelLoading {
            return .orange
        } else if whisperKit.isModelLoaded {
			return whisperKit.whisperKit?.modelState == .unloaded ? .orange : .green
        } else {
            return .secondary
        }
    }
}

