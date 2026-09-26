import Foundation
import Testing

@testable import Whispera

struct WhatsNewTests {

	private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "WhatsNewTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func showsOnceAfterAnUpgrade() {
		let defaults = isolatedDefaults()
		defaults.set("1.2.1", forKey: WhatsNewTracker.lastSeenVersionKey)
		let tracker = WhatsNewTracker(defaults: defaults)

		#expect(tracker.evaluateLaunch(currentVersion: "1.2.2"))
		#expect(defaults.string(forKey: WhatsNewTracker.lastSeenVersionKey) == "1.2.2")
		#expect(!tracker.evaluateLaunch(currentVersion: "1.2.2"))
	}

	@Test func freshInstallRecordsVersionWithoutShowing() {
		let defaults = isolatedDefaults()
		let tracker = WhatsNewTracker(defaults: defaults)
		#expect(!tracker.evaluateLaunch(currentVersion: "1.2.2"))
		#expect(defaults.string(forKey: WhatsNewTracker.lastSeenVersionKey) == "1.2.2")
	}

	@Test func existingUserWithoutRecordedVersionSeesIt() {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: WhatsNewTracker.onboardingKey)
		#expect(WhatsNewTracker(defaults: defaults).evaluateLaunch(currentVersion: "1.2.2"))
	}

	@Test func disabledNeverShowsButStillRecords() {
		let defaults = isolatedDefaults()
		defaults.set("1.0.0", forKey: WhatsNewTracker.lastSeenVersionKey)
		let tracker = WhatsNewTracker(defaults: defaults)
		tracker.isEnabled = false
		#expect(!tracker.evaluateLaunch(currentVersion: "2.0.0"))
		#expect(defaults.string(forKey: WhatsNewTracker.lastSeenVersionKey) == "2.0.0")
	}

	@Test func enabledByDefault() {
		#expect(WhatsNewTracker(defaults: isolatedDefaults()).isEnabled)
	}

	@Test func downgradeOrSameVersionDoesNotShow() {
		#expect(
			!WhatsNewTracker.shouldShow(
				lastSeenVersion: "1.3.0", currentVersion: "1.2.9", hasCompletedOnboarding: true,
				enabled: true))
		#expect(
			!WhatsNewTracker.shouldShow(
				lastSeenVersion: "1.3.0", currentVersion: "1.3.0", hasCompletedOnboarding: true,
				enabled: true))
		#expect(
			WhatsNewTracker.shouldShow(
				lastSeenVersion: "1.9.0", currentVersion: "1.10.0", hasCompletedOnboarding: true,
				enabled: true))
	}

	@Test func releaseURLsTargetTheVersionTag() {
		#expect(
			WhatsNewReleaseNotes.releaseURL(for: "1.2.2")?.absoluteString
				== "https://api.github.com/repos/sapoepsilon/Whispera/releases/tags/v1.2.2")
		#expect(
			WhatsNewReleaseNotes.releasePageURL(for: "1.2.2")?.absoluteString
				== "https://github.com/sapoepsilon/Whispera/releases/tag/v1.2.2")
	}

	@Test func decodesGitHubReleaseBody() throws {
		let json = """
			{"tag_name":"v1.2.2","name":"1.2.2","body":"## Fixes\\n- Faster startup","assets":[]}
			"""
		#expect(try WhatsNewReleaseNotes.decodeBody(from: Data(json.utf8)) == "## Fixes\n- Faster startup")
	}
}

struct WhatsNewNetworkPolicyTests {
	private func defaults() -> UserDefaults {
		let suite = "WhatsNewNetworkPolicyTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func releaseNotesAreFetchedAtLaunchOnlyWhileUpdateChecksAreOn() {
		let store = defaults()
		let tracker = WhatsNewTracker(defaults: store)
		#expect(tracker.updateChecksEnabled)

		store.set(false, forKey: "SUEnableAutomaticChecks")
		#expect(!tracker.updateChecksEnabled, "Turning off update checks in Settings must stop the fetch")

		store.set(true, forKey: "SUEnableAutomaticChecks")
		store.set(false, forKey: "autoCheckForUpdates")
		#expect(!tracker.updateChecksEnabled)
	}
}
