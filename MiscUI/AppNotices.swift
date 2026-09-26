import Foundation
import Observation
import SwiftUI

/// A dismissible message in the menu bar popover for things that changed without the user
/// doing anything, so they are told once instead of finding out later.
struct AppNotice: Identifiable, Equatable {
	enum Kind: String, Hashable {
		case shortcutReset
		case historyIntro
	}

	let kind: Kind
	let message: String

	var id: Kind { kind }

	static func shortcutReset(unreadable: String, boundTo fallback: String) -> AppNotice {
		AppNotice(
			kind: .shortcutReset,
			message: String(
				localized:
					"The shortcut \"\(unreadable)\" could not be read, so it was reset to \(fallback). Choose another one in Settings > General."
			))
	}

	static var historyIntro: AppNotice {
		AppNotice(
			kind: .historyIntro,
			message: String(
				localized:
					"History is on: Whispera keeps your recent transcripts on this Mac so you can copy or retry them. Recordings are not kept unless you turn that on. You can change this any time in Settings > History."
			))
	}
}

@MainActor
@Observable
final class AppNoticeCenter {
	static let shared = AppNoticeCenter(defaults: .standard)

	private(set) var notices: [AppNotice] = []
	@ObservationIgnored private let defaults: UserDefaults

	init(defaults: UserDefaults) {
		self.defaults = defaults
	}

	func post(_ notice: AppNotice) {
		notices.removeAll { $0.kind == notice.kind }
		notices.append(notice)
	}

	func dismiss(_ kind: AppNotice.Kind) {
		notices.removeAll { $0.kind == kind }
		if kind == .historyIntro {
			HistoryIntroNotice.markSeen(in: defaults)
		}
	}

	func turnOffHistory() {
		var settings = HistorySettings(defaults: defaults)
		settings.isEnabled = false
		settings.save(to: defaults)
		AppLogger.shared.general.info("History turned off from the first-run notice")
		dismiss(.historyIntro)
	}

	/// Posts the notices that are owed at launch.
	func postLaunchNotices() {
		if HistoryIntroNotice.shouldShow(in: defaults) {
			post(.historyIntro)
		}
	}
}

/// History is new and on by default, including for people who updated from a version without
/// it, so it is explained once with a way to turn it off.
enum HistoryIntroNotice {
	static let seenKey = "historyIntroNoticeSeen"

	static func shouldShow(in defaults: UserDefaults) -> Bool {
		!defaults.bool(forKey: seenKey) && HistorySettings(defaults: defaults).isEnabled
	}

	static func markSeen(in defaults: UserDefaults) {
		defaults.set(true, forKey: seenKey)
	}
}

/// Defaults applied once when a build with the new features first launches, so people who
/// updated keep the behaviour they had while new installs get the new defaults.
enum UpgradeDefaults {
	static let appliedKey = "upgradeDefaultsApplied"

	/// Must run before anything reads the affected settings. An install that has finished
	/// onboarding before this ever ran predates these features.
	static func apply(to defaults: UserDefaults) {
		ShortcutMigration.migrate(in: defaults)
		guard !defaults.bool(forKey: appliedKey) else { return }
		defaults.set(true, forKey: appliedKey)
		let isUpgrade = defaults.bool(forKey: WhatsNewTracker.onboardingKey)
		guard isUpgrade else { return }
		// Skip Silence drops clips it hears as silent; someone with a quiet mic who never asked
		// for it would lose dictations that used to work
		if defaults.object(forKey: VoiceActivitySettings.enabledKey) == nil {
			defaults.set(false, forKey: VoiceActivitySettings.enabledKey)
			AppLogger.shared.general.info("Skip Silence left off for an existing install")
		}
	}
}

struct AppNoticeBanners: View {
	@State private var center = AppNoticeCenter.shared

	var body: some View {
		if !center.notices.isEmpty {
			VStack(spacing: 8) {
				ForEach(center.notices) { notice in
					banner(for: notice)
				}
			}
		}
	}

	private func banner(for notice: AppNotice) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .top, spacing: 8) {
				Image(systemName: notice.kind == .historyIntro ? "clock.arrow.circlepath" : "keyboard")
					.foregroundColor(.blue)
				Text(notice.message)
					.font(.caption)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				Spacer()
				if notice.kind == .historyIntro {
					Button("Turn Off History") { center.turnOffHistory() }
						.controlSize(.small)
						.accessibilityIdentifier("historyIntroTurnOff")
					Button("Keep On") { center.dismiss(.historyIntro) }
						.controlSize(.small)
						.buttonStyle(.borderedProminent)
						.accessibilityIdentifier("historyIntroKeepOn")
				} else {
					Button("OK") { center.dismiss(notice.kind) }
						.controlSize(.small)
				}
			}
		}
		.padding(10)
		.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
		.overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.3), lineWidth: 1))
	}
}
