import Foundation
import Observation
import SwiftUI

/// A dismissible message in the menu bar popover for things that changed without the user
/// doing anything, so they are told once instead of finding out later.
struct AppNotice: Identifiable, Equatable {
	enum Kind: String, Hashable {
		case shortcutReset
		case historyIntro
		case micStreamPolicyReset
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

	static func micStreamPolicyReset(from policy: MicStreamPolicy) -> AppNotice {
		AppNotice(
			kind: .micStreamPolicyReset,
			message: String(
				localized:
					"Live Transcription Mode is now off by default, so your Microphone Stream choice \"\(policy.displayName)\" would now keep the microphone open. It was set back to \"Open per recording\". Choose it again in Settings > Recording Control if you want it."
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
		if kind == .micStreamPolicyReset {
			MicStreamPolicyMigration.markNoticeSeen(in: defaults)
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
		if let policy = MicStreamPolicyMigration.pendingNotice(in: defaults) {
			post(.micStreamPolicyReset(from: policy))
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

/// Live Transcription Mode used to be on by default, and a kept-open microphone policy did
/// nothing there, so Settings labelled it "No effect". Someone who picked one then and never
/// touched Live Transcription Mode would find the microphone held open once the default went
/// off, so the choice is reverted to the per-recording policy and they are told once.
enum MicStreamPolicyMigration {
	static let appliedKey = "micStreamPolicyLiveDefaultMigrated"
	static let noticeKey = "micStreamPolicyResetNotice"

	/// `stored` must be the persistent domain alone: a registered default is not a choice the
	/// user made. Returns the policy that was reverted, if any.
	@discardableResult
	static func apply(to defaults: UserDefaults, stored: [String: Any]) -> MicStreamPolicy? {
		guard !defaults.bool(forKey: appliedKey) else { return nil }
		defaults.set(true, forKey: appliedKey)
		guard let raw = stored[RecordingControlSettings.Key.micStreamPolicy] as? String,
			let policy = MicStreamPolicy(rawValue: raw), policy != .onDemand,
			stored["enableStreaming"] == nil,
			// Record-to-file never keeps the microphone open, and Parakeet never used live mode
			stored["useStreamingTranscription"] as? Bool ?? true,
			ParakeetModel(rawValue: stored["selectedModel"] as? String ?? "") == nil
		else { return nil }
		defaults.set(MicStreamPolicy.onDemand.rawValue, forKey: RecordingControlSettings.Key.micStreamPolicy)
		defaults.set(policy.rawValue, forKey: noticeKey)
		AppLogger.shared.general.info("Microphone Stream \(policy.rawValue) reverted to onDemand after the Live Transcription Mode default changed")
		return policy
	}

	static func pendingNotice(in defaults: UserDefaults) -> MicStreamPolicy? {
		defaults.string(forKey: noticeKey).flatMap(MicStreamPolicy.init(rawValue:))
	}

	static func markNoticeSeen(in defaults: UserDefaults) {
		defaults.removeObject(forKey: noticeKey)
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
				Image(systemName: icon(for: notice.kind))
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

	private func icon(for kind: AppNotice.Kind) -> String {
		switch kind {
		case .historyIntro: return "clock.arrow.circlepath"
		case .micStreamPolicyReset: return "mic"
		case .shortcutReset: return "keyboard"
		}
	}
}
