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
    @AppStorage("autoExecuteCommands") private var autoExecuteCommands = false
    @AppStorage("globalCommandShortcut") private var globalCommandShortcut = "⌘⌥C"
	var whisperKit = WhisperKitTranscriber.shared
    
    // MARK: - Injected Dependencies
    @State var permissionManager: PermissionManager
    @State var updateManager: UpdateManager
    @State var appLibraryManager: AppLibraryManager
    @State private var availableModels: [String] = []
    @State private var isRecordingShortcut = false
    @State private var eventMonitor: Any?
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingLLMSettings = false
    @State private var showingToolsSettings = false
    @State private var showingSafetySettings = false
    @State private var showingNoUpdateAlert = false
    @State private var showingStorageDetails = false
    @State private var showingClearAllConfirmation = false
    @State private var confirmationStep = 0
    @State private var removingModelId: String?
    
    var body: some View {
        TabView {
            // MARK: - General Tab
            ScrollView {
                VStack(spacing: 16) {
                    // MARK: - App Version Section
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whispera")
                                .font(.headline)
							Text(AppVersion.current.displayString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if updateManager.isCheckingForUpdates {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Button("Check for Updates") {
                                Task {
                                    do {
                                        let hasUpdate = try await updateManager.checkForUpdates()
                                        if !hasUpdate {
                                            showNoUpdateAlert()
                                        }
                                    } catch {
                                        errorMessage = "Failed to check for updates: \(error.localizedDescription)"
                                        showingError = true
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(updateManager.isCheckingForUpdates)
                        }
                    }
                
                // MARK: - Update Notification Banner
                if let latestVersion = updateManager.latestVersion,
                   AppVersion(latestVersion) > AppVersion.current {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                            Text("Update Available")
                                .font(.headline)
                                .foregroundColor(.blue)
                            Spacer()
                        }
                        
                        Text("Whispera \(latestVersion) is available")
                            .font(.body)
                        
                        if let releaseNotes = updateManager.releaseNotes, !releaseNotes.isEmpty {
                            Text(releaseNotes)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                        
                        HStack {
                            if updateManager.isUpdateDownloaded {
                                Button("Install Now") {
                                    Task {
                                        do {
                                            try await updateManager.installDownloadedUpdate()
                                        } catch {
                                            errorMessage = "Failed to install update: \(error.localizedDescription)"
                                            showingError = true
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button("Download Update") {
                                    Task {
                                        do {
                                            try await updateManager.downloadUpdate()
                                        } catch {
                                            errorMessage = "Failed to download update: \(error.localizedDescription)"
                                            showingError = true
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(updateManager.isDownloadingUpdate)
                            }
                            
                            if updateManager.isDownloadingUpdate {
                                ProgressView(value: updateManager.downloadProgress)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Button("View Release Notes") {
                                    if let url = URL(string: "https://github.com/\(AppVersion.Constants.githubRepo)/releases/tag/v\(latestVersion)") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(12)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.blue.opacity(0.3), lineWidth: 1)
                    )
                }
                
                Divider()
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
						.onChange(of: startSound) {
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
                        .onChange(of: stopSound) {
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
									HStack {
										ProgressView(value: whisperKit.downloadProgress)
											.frame(width: 120, height: 4)
										Text("\(whisperKit.downloadProgress * 100, specifier: "%.1f")%")
									}
                                }
                            }
                        } else {
                            VStack(alignment: .trailing, spacing: 4) {
								Picker("Whisper model", selection: Binding(
									get: { whisperKit.selectedModel ?? selectedModel },
									set: { newValue in
										selectedModel = newValue
										whisperKit.selectedModel = newValue
									}
								)) {
									ForEach(whisperKit.availableModels, id: \.self) { model in
										Text(WhisperKitTranscriber.getModelDisplayName(for: model)).tag(model)
									}
								}
								.frame(minWidth: 180)
								.accessibilityIdentifier("Whisper model")
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
                            .accessibilityIdentifier("modelStatusText")
						
						Text("Current memory usage: \(getMemoryUsage().description) MB")
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
                
                Divider()
    
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
                
                if permissionManager.needsPermissions {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: permissionManager.permissionStatusIcon)
                                .foregroundColor(.orange)
                            Text("Required Permissions")
                                .font(.headline)
                                .foregroundColor(.orange)
                            Spacer()
                        }
                        
                        Text(permissionManager.missingPermissionsDescription)
                            .font(.body)
                        
                        if !permissionManager.microphonePermissionGranted {
                            HStack {
                                Text("• Microphone access required for voice recording")
                                    .font(.caption)
                                Spacer()
                                Button("Open Settings") {
                                    permissionManager.openMicrophoneSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        
                        if !permissionManager.accessibilityPermissionGranted {
                            HStack {
                                Text("• Accessibility access required for global shortcuts")
                                    .font(.caption)
                                Spacer()
                                Button("Open Settings") {
                                    permissionManager.openAccessibilitySettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        
                        Button("Open System Settings") {
                            permissionManager.openSystemSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.orange.opacity(0.3), lineWidth: 1)
                    )
                }
                
                Spacer()
            }
            .padding(20)
        }
        .tabItem {
            Label("General", systemImage: "gear")
        }
        
        // MARK: - Storage & Downloads Tab
        ScrollView {
            VStack(spacing: 16) {
                // Storage Summary
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Storage")
                            .font(.headline)
                        Spacer()
                        if appLibraryManager.isCalculatingStorage {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Button("Refresh") {
                                Task {
                                    await appLibraryManager.refreshStorageInfo()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WhisperKit Models")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(appLibraryManager.getStorageSummary())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") {
                            appLibraryManager.openAppLibraryInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    if appLibraryManager.hasModels {
                        HStack {
                            Button("View Details") {
                                showingStorageDetails.toggle()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Spacer()
                            
                            Button("Clear All Models") {
                                showingClearAllConfirmation = true
                                confirmationStep = 0
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundColor(.red)
                        }
                    }
                }
                .padding(12)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.blue.opacity(0.3), lineWidth: 1)
                )
                
                Divider()
                
                // Downloads Location
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Update Downloads")
                            .font(.headline)
                        Spacer()
                    }
                    
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download Location")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if let location = updateManager.downloadLocation {
                                Text("Latest: \(URL(fileURLWithPath: location).lastPathComponent)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("No updates downloaded")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button("Open Downloads") {
                            appLibraryManager.openDownloadsInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.green.opacity(0.3), lineWidth: 1)
                )
                
                Spacer()
            }
            .padding(20)
        }
        .tabItem {
            Label("Storage & Downloads", systemImage: "internaldrive")
        }
    }
        .frame(width: 450, height: 520)
        .background(.regularMaterial)
        .onAppear {
            loadAvailableModels()
            checkLaunchAtStartupStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WhisperKitModelStateChanged"))) { _ in
            // Force UI update when model state changes
            loadAvailableModels()
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
        .alert("Storage Details", isPresented: $showingStorageDetails) {
            Button("OK") { }
        } message: {
            Text(appLibraryManager.getDetailedStorageInfo().joined(separator: "\n"))
        }
        .alert("Clear All Models", isPresented: $showingClearAllConfirmation) {
            if confirmationStep == 0 {
                Button("Cancel", role: .cancel) {
                    confirmationStep = 0
                }
                Button("Continue", role: .destructive) {
					Task {
						do {
							try await appLibraryManager.removeAllModels()
							confirmationStep = 0
						} catch {
							errorMessage = "Failed to clear models: \(error.localizedDescription)"
							showingError = true
							confirmationStep = 0
						}
					}
                }
            }
        } message: {
            if confirmationStep == 0 {
                Text("This will permanently delete all downloaded WhisperKit models. You'll need to re-download them if you want to use them again.\n\nStorage to be freed: \(appLibraryManager.totalStorageFormatted)")
            } else {
                Text("Are you absolutely certain? This action cannot be undone.\n\nAll \(appLibraryManager.modelsCount) models will be permanently deleted.")
            }
        }
    }

    
    private func showNoUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "No Updates Available"
        alert.informativeText = "You're running the latest version of Whispera."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
                    
                    return WhisperKitTranscriber.getModelPriority(for: lhs) < WhisperKitTranscriber.getModelPriority(for: rhs)
                }
                
                await MainActor.run {
                    self.availableModels = allModels
                    
                    // Sync selectedModel with current loaded model if one exists
                    if let currentModel = whisperKit.currentModel, allModels.contains(currentModel) {
                        selectedModel = currentModel
                        whisperKit.selectedModel = currentModel
                    } else if selectedModel.isEmpty || !allModels.contains(selectedModel) {
                        // Set default selection if none set or invalid
                        if let baseModel = allModels.first(where: { $0.contains("base.en") }) {
                            selectedModel = baseModel
                            whisperKit.selectedModel = baseModel
                        } else if let firstModel = allModels.first {
                            selectedModel = firstModel
                            whisperKit.selectedModel = firstModel
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
    
    private func showLLMSettings() {
        showingLLMSettings = true
    }
    
    private func showToolsSettings() {
        showingToolsSettings = true
    }
    
    private func showSafetySettings() {
        showingSafetySettings = true
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
		return whisperKit.modelState
//        if whisperKit.isDownloadingModel {
//            return "Downloading..."
//        } else if whisperKit.isModelLoading {
//            return "Loading..."
//        } else if whisperKit.isModelLoaded {
//            if let currentModel = whisperKit.currentModel {
//                let cleanName = currentModel.replacingOccurrences(of: "openai_whisper-", with: "")
//                // Check if the currently selected model differs from the loaded model
//                if let selectedModel = whisperKit.selectedModel, selectedModel != currentModel {
//                    return "Loaded: \(cleanName) (different model selected)"
//                }
//                return "Loaded: \(cleanName)"
//            } else {
//                return "Model loaded"
//            }
//        } else if whisperKit.isInitialized {
//			return !whisperKit.isCurrentModelLoaded() ? "Different model selected" : "No model loaded"
//        } else {
//            return "Initializing..."
//        }
    }
    
    private func getModelStatusColor() -> Color {
        if whisperKit.isDownloadingModel || whisperKit.isModelLoading {
            return .orange
        } else if whisperKit.isModelLoaded {
            // Check if selected model matches current model
            if let selectedModel = whisperKit.selectedModel, let currentModel = whisperKit.currentModel {
                return selectedModel == currentModel ? .green : .orange
            }
            return whisperKit.isCurrentModelLoaded() ? .green : .orange
        } else {
            return .secondary
        }
    }
    
    private func getMemoryUsage() -> Int {
        // Simple memory usage calculation
        let task = mach_task_self_
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(task, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Int(info.resident_size) / 1024 / 1024 // Convert to MB
        } else {
            return 0
        }
    }
}

