import AppKit
import Foundation
import Testing

@testable import Whispera

private func isolatedDefaults(_ name: String) -> (UserDefaults, () -> Void) {
	let suite = "UpgradeSafetyTests.\(name).\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suite)!
	return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

@MainActor
struct AppNoticeTests {
	@Test func unreadableShortcutNoticeNamesBothKeys() {
		let notice = AppNotice.shortcutReset(unreadable: "⌥?", boundTo: "⌥⌘R")
		#expect(notice.message.contains("⌥?"))
		#expect(notice.message.contains("⌥⌘R"))
	}

	@Test func postingTheSameKindReplacesIt() {
		let (defaults, cleanup) = isolatedDefaults("post")
		defer { cleanup() }
		let center = AppNoticeCenter(defaults: defaults)
		center.post(.shortcutReset(unreadable: "a", boundTo: "⌥⌘R"))
		center.post(.shortcutReset(unreadable: "b", boundTo: "⌥⌘R"))
		#expect(center.notices.count == 1)
		center.dismiss(.shortcutReset)
		#expect(center.notices.isEmpty)
	}

	@Test func historyIntroShowsOnceWhileHistoryIsOn() {
		let (defaults, cleanup) = isolatedDefaults("history")
		defer { cleanup() }
		#expect(HistoryIntroNotice.shouldShow(in: defaults))
		let center = AppNoticeCenter(defaults: defaults)
		center.postLaunchNotices()
		#expect(center.notices.map(\.kind) == [.historyIntro])

		center.dismiss(.historyIntro)
		#expect(!HistoryIntroNotice.shouldShow(in: defaults))
		#expect(HistorySettings(defaults: defaults).isEnabled, "Keep On leaves history on")
		center.postLaunchNotices()
		#expect(center.notices.isEmpty)
	}

	@Test func historyIntroTurnOffDisablesHistory() {
		let (defaults, cleanup) = isolatedDefaults("historyOff")
		defer { cleanup() }
		let center = AppNoticeCenter(defaults: defaults)
		center.postLaunchNotices()
		center.turnOffHistory()
		#expect(!HistorySettings(defaults: defaults).isEnabled)
		#expect(center.notices.isEmpty)
		#expect(!HistoryIntroNotice.shouldShow(in: defaults))
	}

	@Test func historyIntroIsNotShownWhenHistoryIsAlreadyOff() {
		let (defaults, cleanup) = isolatedDefaults("historyAlreadyOff")
		defer { cleanup() }
		defaults.set(false, forKey: HistorySettings.enabledKey)
		#expect(!HistoryIntroNotice.shouldShow(in: defaults))
	}
}

struct UpgradeDefaultsTests {
	@Test func upgradersKeepSkipSilenceOff() {
		let (defaults, cleanup) = isolatedDefaults("upgrader")
		defer { cleanup() }
		defaults.set(true, forKey: WhatsNewTracker.onboardingKey)

		UpgradeDefaults.apply(to: defaults)

		#expect(!VoiceActivitySettings(defaults: defaults).enabled)
	}

	@Test func newInstallsGetSkipSilenceEvenAfterFinishingOnboarding() {
		let (defaults, cleanup) = isolatedDefaults("fresh")
		defer { cleanup() }
		UpgradeDefaults.apply(to: defaults)
		defaults.set(true, forKey: WhatsNewTracker.onboardingKey)
		UpgradeDefaults.apply(to: defaults)

		#expect(VoiceActivitySettings(defaults: defaults).enabled)
		#expect(defaults.object(forKey: VoiceActivitySettings.enabledKey) == nil)
	}

	@Test func anExplicitChoiceIsKept() {
		let (defaults, cleanup) = isolatedDefaults("explicit")
		defer { cleanup() }
		defaults.set(true, forKey: WhatsNewTracker.onboardingKey)
		defaults.set(true, forKey: VoiceActivitySettings.enabledKey)

		UpgradeDefaults.apply(to: defaults)

		#expect(VoiceActivitySettings(defaults: defaults).enabled)
	}

	@Test func legacyShortcutsAreMigratedOnEveryLaunch() {
		let (defaults, cleanup) = isolatedDefaults("shortcut")
		defer { cleanup() }
		UpgradeDefaults.apply(to: defaults)
		defaults.set("⌥ ", forKey: ShortcutDefaults.dictationKey)
		UpgradeDefaults.apply(to: defaults)
		#expect(defaults.string(forKey: ShortcutDefaults.dictationKey) == "⌥Space")
	}

	/// main showed the toggle on while recording treated it as off; both now read one default.
	@Test func keyboardLanguageToggleAndRecordingAgree() {
		let (defaults, cleanup) = isolatedDefaults("keyboard")
		defer { cleanup() }
		AppDelegate.registerInitialDefaults(in: defaults)
		let stored = defaults.bool(forKey: "autoDetectLanguageFromKeyboard")
		#expect(stored == Constants.autoDetectLanguageFromKeyboardDefault)
		#expect(!Constants.autoDetectLanguageFromKeyboardDefault)
	}
}
