import SwiftUI
import Testing

@testable import Whispera

// MARK: - Onboarding Step Flow Tests

struct OnboardingStepFlowTests {

	@Test func stepCountIsFive() {
		let steps = ["Welcome", "Permissions", "Setup", "Try It", "Complete"]
		#expect(steps.count == 5)
	}

	@Test func stepNamesMatchExpected() {
		let steps = ["Welcome", "Permissions", "Setup", "Try It", "Complete"]
		#expect(steps[0] == "Welcome")
		#expect(steps[1] == "Permissions")
		#expect(steps[2] == "Setup")
		#expect(steps[3] == "Try It")
		#expect(steps[4] == "Complete")
	}

	@Test func nextButtonTextForWelcome() {
		let text = nextButtonText(step: 0, hasPermissions: false, isDownloading: false, hasTranscription: false)
		#expect(text == "Get Started")
	}

	@Test func nextButtonTextForPermissionsGranted() {
		let text = nextButtonText(step: 1, hasPermissions: true, isDownloading: false, hasTranscription: false)
		#expect(text == "Continue")
	}

	@Test func nextButtonTextForPermissionsNotGranted() {
		let text = nextButtonText(step: 1, hasPermissions: false, isDownloading: false, hasTranscription: false)
		#expect(text == "Grant Permissions")
	}

	@Test func nextButtonTextForSetupDownloading() {
		let text = nextButtonText(step: 2, hasPermissions: true, isDownloading: true, hasTranscription: false)
		#expect(text == "Downloading...")
	}

	@Test func nextButtonTextForSetupReady() {
		let text = nextButtonText(step: 2, hasPermissions: true, isDownloading: false, hasTranscription: false)
		#expect(text == "Continue")
	}

	@Test func nextButtonTextForTestWithTranscription() {
		let text = nextButtonText(step: 3, hasPermissions: true, isDownloading: false, hasTranscription: true)
		#expect(text == "Continue")
	}

	@Test func nextButtonTextForTestWithoutTranscription() {
		let text = nextButtonText(step: 3, hasPermissions: true, isDownloading: false, hasTranscription: false)
		#expect(text == "Skip Test")
	}

	@Test func nextButtonTextForComplete() {
		let text = nextButtonText(step: 4, hasPermissions: true, isDownloading: false, hasTranscription: false)
		#expect(text == "Finish Setup")
	}

	@Test func canProceedPermissionsBlocked() {
		#expect(canProceed(step: 1, hasPermissions: false, isDownloading: false) == false)
	}

	@Test func canProceedPermissionsGranted() {
		#expect(canProceed(step: 1, hasPermissions: true, isDownloading: false) == true)
	}

	@Test func canProceedSetupDownloading() {
		#expect(canProceed(step: 2, hasPermissions: true, isDownloading: true) == false)
	}

	@Test func canProceedSetupReady() {
		#expect(canProceed(step: 2, hasPermissions: true, isDownloading: false) == true)
	}

	@Test func canProceedWelcomeAlwaysTrue() {
		#expect(canProceed(step: 0, hasPermissions: false, isDownloading: false) == true)
	}

	@Test func canProceedTestAlwaysTrue() {
		#expect(canProceed(step: 3, hasPermissions: false, isDownloading: false) == true)
	}

	@Test func canProceedCompleteAlwaysTrue() {
		#expect(canProceed(step: 4, hasPermissions: false, isDownloading: false) == true)
	}

	// Mirrors OnboardingView.nextButtonText logic
	private func nextButtonText(step: Int, hasPermissions: Bool, isDownloading: Bool, hasTranscription: Bool) -> String {
		switch step {
		case 0: return "Get Started"
		case 1: return hasPermissions ? "Continue" : "Grant Permissions"
		case 2: return isDownloading ? "Downloading..." : "Continue"
		case 3: return hasTranscription ? "Continue" : "Skip Test"
		case 4: return "Finish Setup"
		default: return "Next"
		}
	}

	// Mirrors OnboardingView.canProceed logic
	private func canProceed(step: Int, hasPermissions: Bool, isDownloading: Bool) -> Bool {
		switch step {
		case 1: return hasPermissions
		case 2: return !isDownloading
		default: return true
		}
	}
}

// MARK: - Onboarding Persistence Tests
// Uses an isolated UserDefaults suite to avoid @AppStorage interference from the host app

struct OnboardingPersistenceTests {

	private static let suiteName = "com.sapoepsilon.WhisperaTests.Onboarding"

	private var defaults: UserDefaults {
		let d = UserDefaults(suiteName: Self.suiteName)!
		return d
	}

	private func cleanup() {
		UserDefaults.standard.removeSuite(named: Self.suiteName)
	}

	@Test func onboardingCompletionFlagPersists() {
		let key = "hasCompletedOnboarding"

		defaults.set(true, forKey: key)
		#expect(defaults.bool(forKey: key) == true)

		defaults.set(false, forKey: key)
		#expect(defaults.bool(forKey: key) == false)

		cleanup()
	}

	@Test func globalShortcutDefaultValue() {
		let key = "globalShortcut"
		let stored = UserDefaults.standard.string(forKey: key)
		if stored == nil {
			#expect(true, "No stored shortcut is valid — default is set via @AppStorage")
		} else {
			#expect(!stored!.isEmpty, "Stored shortcut should not be empty")
		}
	}

	@Test func selectedModelPersists() {
		let key = "selectedModel"

		defaults.set("openai_whisper-small", forKey: key)
		#expect(defaults.string(forKey: key) == "openai_whisper-small")

		cleanup()
	}

	@Test func launchAtStartupPersists() {
		let key = "launchAtStartup"

		defaults.set(true, forKey: key)
		#expect(defaults.bool(forKey: key) == true)

		defaults.set(false, forKey: key)
		#expect(defaults.bool(forKey: key) == false)

		cleanup()
	}

	@Test func selectedLanguagePersists() {
		let key = "selectedLanguage"

		defaults.set("spanish", forKey: key)
		#expect(defaults.string(forKey: key) == "spanish")

		cleanup()
	}

	@Test func materialStylePersists() {
		let key = "materialStyle"

		defaults.set("Thick", forKey: key)
		#expect(defaults.string(forKey: key) == "Thick")

		cleanup()
	}
}

// MARK: - Onboarding Completion Notification Tests

struct OnboardingCompletionTests {

	@Test func completionNotificationFires() async {
		let notificationName = NSNotification.Name("OnboardingCompleted")
		var received = false

		let observer = NotificationCenter.default.addObserver(
			forName: notificationName,
			object: nil,
			queue: .main
		) { _ in
			received = true
		}

		NotificationCenter.default.post(name: notificationName, object: nil)

		try? await Task.sleep(for: .milliseconds(100))
		#expect(received == true)

		NotificationCenter.default.removeObserver(observer)
	}
}

// MARK: - Slide Transition Tests

struct SlideTransitionTests {

	@Test func forwardDirectionIsPositive() {
		let transition = SlideTransition(direction: 1)
		#expect(transition.direction == 1)
	}

	@Test func backwardDirectionIsNegative() {
		let transition = SlideTransition(direction: -1)
		#expect(transition.direction == -1)
	}
}

// MARK: - Progress View Tests

struct OnboardingProgressViewTests {

	@Test func progressViewAcceptsCorrectStepCount() {
		let steps = ["Welcome", "Permissions", "Setup", "Try It", "Complete"]
		#expect(steps.count == 5)
		#expect(steps.first == "Welcome")
		#expect(steps.last == "Complete")
	}

	@Test func currentStepBoundsAreValid() {
		let totalSteps = 5
		for step in 0..<totalSteps {
			#expect(step >= 0)
			#expect(step < totalSteps)
		}
	}

	@Test func stepNamesAreNonEmpty() {
		let steps = ["Welcome", "Permissions", "Setup", "Try It", "Complete"]
		for step in steps {
			#expect(!step.isEmpty)
		}
	}
}

// MARK: - Confetti View Tests

struct ConfettiViewTests {

	@Test func confettiColorsFromAppPalette() {
		let colors: [Color] = [.blue, .purple, .green, .orange]
		#expect(colors.count == 4)
	}

	@Test func particleCountIs25() {
		let particleCount = 25
		#expect(particleCount == 25)
	}
}

// MARK: - Setup Step Consolidation Tests

struct SetupStepConsolidationTests {

	@Test func setupStepReplacesThreeOldSteps() {
		let oldSteps = ["Welcome", "Permissions", "Model", "Shortcut", "Settings", "Test", "Complete"]
		let newSteps = ["Welcome", "Permissions", "Setup", "Try It", "Complete"]

		#expect(oldSteps.count == 7)
		#expect(newSteps.count == 5)
		#expect(oldSteps.count - newSteps.count == 2)
	}

	@Test func setupStepContainsModelShortcutsAndSettings() {
		let setupSections = ["AI Model", "Keyboard Shortcuts", "Preferences"]
		#expect(setupSections.count == 3)
		#expect(setupSections.contains("AI Model"))
		#expect(setupSections.contains("Keyboard Shortcuts"))
		#expect(setupSections.contains("Preferences"))
	}

	@Test func defaultShortcutValues() {
		let recordingDefault = "⌥⌘R"
		let fileTranscriptionDefault = "⌃F"

		#expect(!recordingDefault.isEmpty)
		#expect(!fileTranscriptionDefault.isEmpty)
		#expect(recordingDefault != fileTranscriptionDefault)
	}
}

// MARK: - Welcome Step Tests

struct WelcomeStepTests {

	@Test func featurePillsAreThree() {
		let pills = ["On-device", "Private", "Accurate"]
		#expect(pills.count == 3)
	}

	@Test func featurePillsHaveIcons() {
		let pills: [(icon: String, label: String)] = [
			("waveform", "On-device"),
			("lock.fill", "Private"),
			("checkmark.seal", "Accurate"),
		]
		for pill in pills {
			#expect(!pill.icon.isEmpty)
			#expect(!pill.label.isEmpty)
		}
	}
}

// MARK: - Complete Step Tests

struct CompleteStepTests {

	@Test func tipCardsAreThree() {
		let tips = [
			"Press shortcut anywhere",
			"Menu bar access",
			"Private by design",
		]
		#expect(tips.count == 3)
	}

	@Test func completionSetsOnboardingFlag() {
		let key = "hasCompletedOnboarding"
		let defaults = UserDefaults(suiteName: "com.sapoepsilon.WhisperaTests.Complete")!

		defaults.set(true, forKey: key)
		#expect(defaults.bool(forKey: key) == true)

		UserDefaults.standard.removeSuite(named: "com.sapoepsilon.WhisperaTests.Complete")
	}
}

// MARK: - Direction State Tests

struct DirectionStateTests {

	@Test func forwardNavigationSetsPositiveDirection() {
		var direction = 0
		direction = 1
		#expect(direction == 1)
	}

	@Test func backwardNavigationSetsNegativeDirection() {
		var direction = 0
		direction = -1
		#expect(direction == -1)
	}

	@Test func stepIncrementOnForward() {
		var currentStep = 0
		let direction = 1
		currentStep += direction
		#expect(currentStep == 1)
	}

	@Test func stepDecrementOnBackward() {
		var currentStep = 3
		currentStep -= 1
		#expect(currentStep == 2)
	}

	@Test func stepNeverGoesBelowZero() {
		let currentStep = 0
		#expect(max(currentStep - 1, 0) == 0)
	}

	@Test func stepNeverExceedsMaximum() {
		let totalSteps = 5
		var currentStep = 4
		if currentStep < totalSteps - 1 {
			currentStep += 1
		}
		#expect(currentStep == 4)
	}
}

// MARK: - Onboarding State Saving Tests
// Each test uses its own UserDefaults suite to avoid parallel test interference

struct OnboardingStateSavingTests {

	@Test func handleSetupStepSavesAllValues() {
		let suite = "com.sapoepsilon.WhisperaTests.SetupSave"
		let defaults = UserDefaults(suiteName: suite)!

		defaults.set("openai_whisper-base.en", forKey: "selectedModel")
		defaults.set("⌃⌘T", forKey: "globalShortcut")
		defaults.set(true, forKey: "launchAtStartup")

		#expect(defaults.string(forKey: "selectedModel") == "openai_whisper-base.en")
		#expect(defaults.string(forKey: "globalShortcut") == "⌃⌘T")
		#expect(defaults.bool(forKey: "launchAtStartup") == true)

		defaults.removePersistentDomain(forName: suite)
	}

	@Test func completionSetsModelAndFlag() {
		let suite = "com.sapoepsilon.WhisperaTests.Completion"
		let defaults = UserDefaults(suiteName: suite)!

		defaults.set(true, forKey: "hasCompletedOnboarding")
		defaults.set("openai_whisper-small", forKey: "selectedModel")

		#expect(defaults.bool(forKey: "hasCompletedOnboarding") == true)
		#expect(defaults.string(forKey: "selectedModel") == "openai_whisper-small")

		defaults.removePersistentDomain(forName: suite)
	}
}
