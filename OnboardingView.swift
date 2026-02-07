import AVFoundation
import SwiftUI

struct OnboardingView: View {
	@Bindable var audioManager: AudioManager
	@ObservedObject var shortcutManager: GlobalShortcutManager

	@State private var currentStep = 0
	@State private var direction: Int = 1
	@State private var selectedModel = ""
	@State private var customShortcut = ""
	@State private var hasPermissions = false
	@State private var launchAtLogin = false

	@AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
	@AppStorage("globalShortcut") private var globalShortcut = "⌥⌘R"
	@AppStorage("selectedModel") private var storedModel = ""
	@AppStorage("launchAtStartup") private var storedLaunchAtLogin = false
	@AppStorage("enableStreaming") private var enableStreaming = true
	@AppStorage("selectedLanguage") private var selectedLanguage = Constants.defaultLanguageName
	@AppStorage("materialStyle") private var materialStyleRaw = MaterialStyle.default.rawValue

	private var materialStyle: MaterialStyle {
		MaterialStyle(rawValue: materialStyleRaw)
	}

	private let steps = ["Welcome", "Permissions", "Setup", "Try It", "Complete"]

	var body: some View {
		VStack(spacing: 0) {
			OnboardingProgressView(
				currentStep: currentStep,
				totalSteps: steps.count,
				stepNames: steps
			)
			.padding(.horizontal, 40)
			.padding(.top, 30)
			.padding(.bottom, 16)

			ZStack {
				stepContent
					.id(currentStep)
					.transition(SlideTransition(direction: direction))
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.clipped()
			.animation(.spring(duration: 0.5, bounce: 0.18), value: currentStep)

			HStack(spacing: 16) {
				if currentStep > 0 {
					Button("Back") {
						direction = -1
						withAnimation {
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
			.padding(.top, 8)
		}
		.background(materialStyle.material)
		.overlay(
			LinearGradient(
				colors: [Color.blue.opacity(0.02), Color.clear],
				startPoint: .top,
				endPoint: .center
			)
			.allowsHitTesting(false)
		)
		.frame(width: 600, height: 750)
		.onAppear {
			checkPermissions()
			customShortcut = globalShortcut
			launchAtLogin = storedLaunchAtLogin
		}
	}

	@ViewBuilder
	private var stepContent: some View {
		switch currentStep {
		case 0:
			WelcomeStepView()
		case 1:
			PermissionsStepView(
				hasPermissions: $hasPermissions,
				audioManager: audioManager,
				globalShortcutManager: shortcutManager
			)
		case 2:
			SetupStepView(
				selectedModel: $selectedModel,
				customShortcut: $customShortcut,
				launchAtLogin: $launchAtLogin,
				audioManager: audioManager
			)
		case 3:
			TestStepView(
				audioManager: audioManager,
				selectedLanguage: $selectedLanguage
			)
			.padding(.horizontal, 40)
		case 4:
			CompleteStepView()
				.padding(.horizontal, 40)
		default:
			EmptyView()
		}
	}

	private var nextButtonText: String {
		switch currentStep {
		case 0: return "Get Started"
		case 1: return hasPermissions ? "Continue" : "Grant Permissions"
		case 2:
			return audioManager.whisperKitTranscriber.isDownloadingModel
				? "Downloading..." : "Continue"
		case 3: return audioManager.lastTranscription != nil ? "Continue" : "Skip Test"
		case 4: return "Finish Setup"
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
			storedModel = selectedModel
			globalShortcut = customShortcut
			shortcutManager.currentShortcut = customShortcut
			storedLaunchAtLogin = launchAtLogin
		case 3:
			break
		case 4:
			completeOnboarding()
			return
		default:
			break
		}

		direction = 1
		withAnimation {
			currentStep += 1
		}
	}

	private func checkPermissions() {
		hasPermissions = AXIsProcessTrusted()
	}

	private func requestPermissions() {
		let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
		AXIsProcessTrustedWithOptions(options)

		if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
			AVCaptureDevice.requestAccess(for: .audio) { _ in }
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
			checkPermissions()
		}
	}

	private func completeOnboarding() {
		hasCompletedOnboarding = true
		storedModel = selectedModel
		NotificationCenter.default.post(
			name: NSNotification.Name("OnboardingCompleted"), object: nil)
	}
}
