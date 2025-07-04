import SwiftUI
import AVFoundation

struct OnboardingView: View {
	@Bindable var audioManager: AudioManager
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
    @AppStorage("enableTranslation") private var enableTranslation = false
    @AppStorage("selectedLanguage") private var selectedLanguage = Constants.defaultLanguageName
    
    private let steps = ["Welcome", "Permissions", "Model", "Shortcut", "Settings", "Test", "Complete"]
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Welcome to Whispera")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                OnboardingProgressView(currentStep: currentStep, totalSteps: steps.count)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 20)
            
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
        .frame(width: 600, height: 750)
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
            TestStepView(audioManager: audioManager, enableTranslation: $enableTranslation, selectedLanguage: $selectedLanguage)
        case 6:
            CompleteStepView()
        default:
            EmptyView()
        }
    }
    
    private var nextButtonText: String {
        switch currentStep {
        case 0: return "Get Started"
        case 1: return (hasPermissions) ? "Continue" : "Grant Permissions"
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
        case 1: return hasPermissions
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
