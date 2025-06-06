import SwiftUI
import AVFoundation


struct OnboardingView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var shortcutManager: GlobalShortcutManager
    
    @State private var currentStep = 0
    @State private var selectedModel = ""
    @State private var customShortcut = ""
    @State private var hasPermissions = false
    @State private var launchAtLogin = false
    @State private var showingShortcutCapture = false
    
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("globalShortcut") private var globalShortcut = "⌥⌘R"
    @AppStorage("selectedModel") private var storedModel = ""
    @AppStorage("launchAtStartup") private var storedLaunchAtLogin = false
    
    private let steps = ["Welcome", "Permissions", "Model", "Shortcut", "Settings", "Test", "Complete"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("Welcome to Whispera")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                
                // Progress indicator
                OnboardingProgressView(currentStep: currentStep, totalSteps: steps.count)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 20)
            
            // Content area
            ScrollView {
                VStack(spacing: 30) {
                    stepContent
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 30)
            }
            
            // Navigation buttons
            HStack(spacing: 16) {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                
                Spacer()
                
                Button(nextButtonText) {
                    handleNextStep()
                }
                .buttonStyle(PrimaryButtonStyle(isRecording: false))
                .disabled(!canProceed)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .background(.regularMaterial)
        .frame(width: 600, height: 700)
        .onAppear {
            checkPermissions()
            // Initialize customShortcut with stored value
            customShortcut = globalShortcut
            // Initialize launchAtLogin with stored value
            launchAtLogin = storedLaunchAtLogin
        }
    }
    
    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            WelcomeStepView()
        case 1:
			PermissionsStepView(hasPermissions: $hasPermissions, audioManager: audioManager, globalShortcutManager: shortcutManager)
        case 2:
            ModelSelectionStepView(selectedModel: $selectedModel, audioManager: audioManager)
        case 3:
            ShortcutStepView(customShortcut: $customShortcut, showingShortcutCapture: $showingShortcutCapture)
        case 4:
            SettingsStepView(launchAtLogin: $launchAtLogin)
        case 5:
            TestStepView(audioManager: audioManager)
        case 6:
            CompleteStepView()
        default:
            EmptyView()
        }
    }
    
    private var nextButtonText: String {
        switch currentStep {
        case 0: return "Get Started"
        case 1: return (hasPermissions && checkMicrophonePermissionStatus()) ? "Continue" : "Grant Permissions"
        case 2: return audioManager.whisperKitTranscriber.isDownloadingModel ? "Downloading..." : "Continue"
        case 3: return "Set Shortcut"
        case 4: return "Continue"
        case 5: return audioManager.lastTranscription != nil ? "Continue" : "Skip Test"
        case 6: return "Finish Setup"
        default: return "Next"
        }
    }
    
    private var canProceed: Bool {
        switch currentStep {
        case 1: return hasPermissions && checkMicrophonePermissionStatus()
        case 2: return !audioManager.whisperKitTranscriber.isDownloadingModel
        default: return true
        }
    }
    
    private func handleNextStep() {
        switch currentStep {
        case 1:
            if !hasPermissions {
                requestPermissions()
                return
            }
        case 2:
            // Model selection step - model should already be downloaded
            storedModel = selectedModel
        case 3:
            globalShortcut = customShortcut
            shortcutManager.currentShortcut = customShortcut
        case 4:
            storedLaunchAtLogin = launchAtLogin
        case 5:
            if audioManager.lastTranscription == nil && nextButtonText != "Skip Test" {
                return
            }
        case 6:
            completeOnboarding()
            return
        default:
            break
        }
        
        withAnimation() {
            currentStep += 1
        }
    }
    
    private func checkPermissions() {
        hasPermissions = AXIsProcessTrusted()
    }
    
    private func requestPermissions() {
        // Request accessibility permissions
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
        
        // Request microphone permissions if needed
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // Permission response handled by the view update
            }
        }
        
        // Check again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            checkPermissions()
        }
    }
    
    private func completeOnboarding() {
        hasCompletedOnboarding = true
        storedModel = selectedModel

        NotificationCenter.default.post(name: NSNotification.Name("OnboardingCompleted"), object: nil)
    }
    
    private func checkMicrophonePermissionStatus() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

// MARK: - Welcome Step
struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            // App icon and title
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)
                
                VStack(spacing: 8) {
                    Text("Welcome to Whispera")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    
                    Text("Whisper-powered voice transcription for macOS")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            
            // Feature highlights
            VStack(spacing: 16) {
                FeatureRowView(
                    icon: "mic.fill",
                    title: "Global Voice Recording",
                    description: "Record from anywhere with a keyboard shortcut"
                )
                
                FeatureRowView(
                    icon: "brain.head.profile",
                    title: "AI-Powered Transcription",
                    description: "Local processing with OpenAI Whisper models"
                )
                
                FeatureRowView(
                    icon: "lock.shield",
                    title: "Privacy First",
                    description: "Everything stays on your Mac - no cloud required"
                )
                
                FeatureRowView(
                    icon: "speedometer",
                    title: "Lightning Fast",
                    description: "Optimized for Apple Silicon and Intel Macs"
                )
            }
            
            Text("Let's get you set up in just a few steps!")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.top, 8)
        }
    }
}

// MARK: - Permissions Step
struct PermissionsStepView: View {
    @Binding var hasPermissions: Bool
	@ObservedObject var audioManager: AudioManager
	@ObservedObject var globalShortcutManager: GlobalShortcutManager
    @State private var hasMicrophonePermission = false
    @State private var permissionCheckTimer: Timer?
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                
                Text("Permissions Required")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                
                Text("Whispera needs accessibility permissions to work with global keyboard shortcuts.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                PermissionRowView(
                    icon: "key.fill",
                    title: "Accessibility Access",
                    description: "Required for global keyboard shortcuts",
                    isGranted: hasPermissions
                )
				
				if !hasPermissions {
					Button {
						globalShortcutManager.requestAccessibilityPermissions()
						startPermissionChecking()
					} label: {
						Text("Grant Accessibility Access")
					}
				}
				
                PermissionRowView(
                    icon: "mic.fill",
                    title: "Microphone Access",
                    description: "Required for voice recording",
                    isGranted: hasMicrophonePermission
                )
				if !hasMicrophonePermission {
					VStack(spacing: 8) {
						Button {
							audioManager.setupAudio()
							// Trigger actual microphone usage to force system dialog
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
								audioManager.toggleRecording()
							}
						} label: {
							Text("Grant Microphone Access")
						}
						
						Button {
							openMicrophoneSettings()
						} label: {
							Text("Open Microphone Settings")
								.font(.caption)
						}
						.buttonStyle(.plain)
						.foregroundColor(.blue)
					}
				}
            }
            
            if hasPermissions && hasMicrophonePermission {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("All permissions granted! You're ready to continue.")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }
                .padding()
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 12) {
                    if !hasPermissions {
                        Text("After clicking \"Grant Permissions\", you'll see a system dialog.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Text("Go to System Settings > Privacy & Security > Accessibility and enable Whispera.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    if !hasMicrophonePermission {
                        VStack(spacing: 8) {
                            Text("Microphone access will be requested when you first try to record.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            
                            Text("If Whispera doesn't appear in Microphone settings, try recording first to trigger the permission request.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding()
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            checkMicrophonePermission()
            checkAccessibilityPermission()
        }
        .onDisappear {
            stopPermissionChecking()
        }
    }
    
    private func checkMicrophonePermission() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    private func checkAccessibilityPermission() {
        hasPermissions = AXIsProcessTrusted()
    }
    
    private func startPermissionChecking() {
        // Check immediately
        checkAccessibilityPermission()
        
        // Then check every 0.5 seconds for changes
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            checkAccessibilityPermission()
            checkMicrophonePermission()
            
            // Stop checking once both permissions are granted
            if hasPermissions && hasMicrophonePermission {
                stopPermissionChecking()
            }
        }
    }
    
    private func stopPermissionChecking() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }
    
    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Supporting Views
struct FeatureRowView: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

struct PermissionRowView: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isGranted ? .green.opacity(0.2) : .gray.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(isGranted ? .green : .gray)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isGranted ? .green : .gray)
        }
        .padding()
        .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct OnboardingProgressView: View {
    let currentStep: Int
    let totalSteps: Int
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? .blue : .gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.3), value: currentStep)
                }
            }
            
            Text("Step \(currentStep + 1) of \(totalSteps)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Shortcut Step
struct ShortcutStepView: View {
    @Binding var customShortcut: String
    @Binding var showingShortcutCapture: Bool
    @State private var isCapturing = false
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "keyboard")
                    .font(.system(size: 48))
                    .foregroundColor(.purple)
                
                Text("Set Your Shortcut")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                
                Text("Choose a keyboard shortcut to quickly start recording from anywhere.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                Text("Current shortcut:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Text(customShortcut)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    
                    Button("Change") {
                        showShortcutOptions()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                
                if showingShortcutCapture {
                    ShortcutOptionsView(customShortcut: $customShortcut, showingOptions: $showingShortcutCapture)
                }
                
                Text("You can change this later in Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func showShortcutOptions() {
        showingShortcutCapture.toggle()
    }
}

// MARK: - Settings Step
struct SettingsStepView: View {
    @Binding var launchAtLogin: Bool
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "gear.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                
                Text("App Settings")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                
                Text("Configure how Whispera behaves on your system.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                SettingRowView(
                    icon: "power",
                    title: "Launch at Login",
                    description: "Start Whispera automatically when you log in",
                    isOn: $launchAtLogin
                )
            }
        }
    }
}

// MARK: - Shortcut Options View
struct ShortcutOptionsView: View {
    @Binding var customShortcut: String
    @Binding var showingOptions: Bool
    @State private var isRecordingShortcut = false
    @State private var eventMonitor: Any?
    
    private let shortcutOptions = [
        "⌥⌘R", "⌃⌘R", "⇧⌘R",
        "⌥⌘T", "⌃⌘T", "⇧⌘T",
        "⌥⌘V", "⌃⌘V", "⇧⌘V"
    ]
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Choose a shortcut:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Custom shortcut recording section
            VStack(spacing: 12) {
                HStack {
                    Text("Record Custom:")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Group {
                        if isRecordingShortcut {
                            Button(action: {
                                stopRecording()
                            }) {
                                Text("Press keys...")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minWidth: 80)
                            }
                            .buttonStyle(PrimaryButtonStyle(isRecording: true))
                            .foregroundColor(.white)
                        } else {
                            Button(action: {
                                startRecording()
                            }) {
                                Text("Record New")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minWidth: 80)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .foregroundColor(.primary)
                        }
                    }
                }
                
                if isRecordingShortcut {
                    Text("Press Command, Option, Control or Shift + another key")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            
            Text("Or choose a preset:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(shortcutOptions, id: \.self) { shortcut in
                    Group {
                        if shortcut == customShortcut {
                            Button(shortcut) {
                                customShortcut = shortcut
                                showingOptions = false
                            }
                            .buttonStyle(PrimaryButtonStyle(isRecording: false))
                            .font(.system(.caption, design: .monospaced))
                        } else {
                            Button(shortcut) {
                                customShortcut = shortcut
                                showingOptions = false
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            
            Button("Cancel") {
                showingOptions = false
            }
            .buttonStyle(TertiaryButtonStyle())
            .font(.caption)
        }
        .padding()
        .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        .onDisappear {
            stopRecording()
        }
    }
    
    private func startRecording() {
        isRecordingShortcut = true
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if self.isRecordingShortcut {
                let shortcut = self.formatKeyEvent(event)
                if !shortcut.isEmpty {
                    self.customShortcut = shortcut
                    self.stopRecording()
                    self.showingOptions = false
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
}

// MARK: - Setting Row View
struct SettingRowView: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding()
        .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Test Step
struct TestStepView: View {
    @ObservedObject var audioManager: AudioManager
    @AppStorage("globalShortcut") private var globalShortcut = "⌥⌘R"
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                
                Text("Test Your Setup")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                
                Text("Try your global shortcut to test voice transcription.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
				
				Text("The first transcription might take longer due to the model loading on your device. Especially if it is a larger model.")
					.font(.callout)
					.multilineTextAlignment(.center)

            }
            
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Text("Press your shortcut to start recording:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text(globalShortcut)
                        .font(.system(.title, design: .monospaced, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundColor(.blue)
                }
                
                if audioManager.isRecording {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Recording... (press shortcut again to stop)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                
                if audioManager.isTranscribing {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Transcribing...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let transcription = audioManager.lastTranscription, !transcription.isEmpty {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Transcription Complete!")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Transcribed Text:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(transcription)
                                .font(.system(.body, design: .default))
                                .padding()
                                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                .textSelection(.enabled)
                        }
                        
                        Button("Copy to Clipboard") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcription, forType: .string)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .font(.caption)
                    }
                    .padding()
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                
                if !audioManager.whisperKitTranscriber.isInitialized {
                    Text("Waiting for AI framework to initialize...")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if !audioManager.whisperKitTranscriber.hasAnyModel() {
                    Text("Please download a model first to enable transcription.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Ready for testing! Use your global shortcut to test.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

// MARK: - Model Selection Step
struct ModelSelectionStepView: View {
    @Binding var selectedModel: String
    @ObservedObject var audioManager: AudioManager
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var loadingError: String?
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                
                Text("Choose AI Model")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                
                Text("Select the AI model that best fits your needs. You can change this later in Settings.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                HStack {
                    Text("AI Model")
                        .font(.headline)
                    Spacer()
                    
                    if isLoadingModels {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading models...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(getModelOptions(), id: \.0) { model in
                                Text(model.1).tag(model.0)
                            }
                        }
                        .frame(minWidth: 220)
                    }
                }
                
                Text("Choose your AI model: base is fast and accurate for most use cases, small provides better accuracy for complex speech, and tiny is fastest for simple transcriptions.")
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
                            Text("Downloading \(audioManager.whisperKitTranscriber.downloadingModelName ?? "model")...")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        
                        ProgressView(value: audioManager.whisperKitTranscriber.downloadProgress)
                            .frame(height: 4)
                    }
                    .padding()
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                
                Text("Models are downloaded once and stored locally. Your voice data never leaves your Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            loadAvailableModels()
        }
        .onChange(of: selectedModel) { newModel in
            downloadModelIfNeeded(newModel)
        }
    }
    
    private func getModelOptions() -> [(String, String)] {
        if availableModels.isEmpty {
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
        isLoadingModels = true
        loadingError = nil
        
        Task {
            do {
                // Use WhisperKitTranscriber to fetch available models
                try await audioManager.whisperKitTranscriber.refreshAvailableModels()
                let fetchedModels = audioManager.whisperKitTranscriber.availableModels
                
                await MainActor.run {
                    self.availableModels = fetchedModels.sorted { lhs, rhs in
                        getModelPriority(lhs) < getModelPriority(rhs)
                    }
                    self.isLoadingModels = false
                    
                    // Set default selection if none set or invalid
                    if selectedModel.isEmpty || !fetchedModels.contains(selectedModel) {
                        // Find the first base model (preferred) or fallback to first available
                        if let baseModel = fetchedModels.first(where: { $0.contains("base.en") }) {
                            selectedModel = baseModel
                        } else if let firstModel = fetchedModels.first {
                            selectedModel = firstModel
                        } else {
                            selectedModel = "openai_whisper-base.en"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.loadingError = error.localizedDescription
                    self.isLoadingModels = false
                    // Use fallback models
                    self.availableModels = [
                        "openai_whisper-tiny.en",
                        "openai_whisper-base.en", 
                        "openai_whisper-small.en"
                    ]
                    if selectedModel.isEmpty {
                        if let baseModel = self.availableModels.first(where: { $0.contains("base.en") }) {
                            selectedModel = baseModel
                        } else if let firstModel = self.availableModels.first {
                            selectedModel = firstModel
                        } else {
                            selectedModel = "openai_whisper-base.en"
                        }
                    }
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
    
    private func downloadModelIfNeeded(_ modelId: String) {
        // Only download if not already downloaded and not currently downloading
        if !audioManager.whisperKitTranscriber.downloadedModels.contains(modelId) &&
           !audioManager.whisperKitTranscriber.isDownloadingModel {
            Task {
                do {
                    try await audioManager.whisperKitTranscriber.downloadModel(modelId)
                } catch {
                    await MainActor.run {
                        loadingError = "Failed to download model: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}


// MARK: - Complete Step
struct CompleteStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.green)
                
                Text("You're All Set!")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                
                Text("Whispera is now configured and ready to use.")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 16) {
                Text("Quick Tips:")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Press your shortcut from anywhere to start recording")
                    Text("• Click the menu bar icon to see recent transcriptions")
                    Text("• Visit Settings to customize models and shortcuts")
                    Text("• Your voice data never leaves your Mac")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
