// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import Foundation

extension WhisperaSettings {
	private static let pauseMediaKey = "whisperaPauseMediaWhileDictating"
	private static let mediaKeyFallbackKey = "whisperaPauseMediaUsesMediaKey"

	/// Tier 1: pause Music/Spotify through Apple Events. Default ON.
	static var pauseMediaWhileDictating: Bool {
		// `bool(forKey:)` can't express "absent means true", so read the object.
		get { UserDefaults.standard.object(forKey: pauseMediaKey) as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: pauseMediaKey) }
	}

	/// Tier 2: blind system play/pause key for players we can't script. Default OFF.
	static var pauseMediaUsesMediaKey: Bool {
		get { UserDefaults.standard.bool(forKey: mediaKeyFallbackKey) }
		set { UserDefaults.standard.set(newValue, forKey: mediaKeyFallbackKey) }
	}
}

/// A media app Whispera can script. Raw value is the AppleScript application name.
enum MediaApp: String, CaseIterable, Sendable {
	case music = "Music"
	case spotify = "Spotify"

	/// Token the pause script echoes back so we know exactly what we paused.
	var token: String { rawValue.lowercased() }
}

/// Pauses whatever the user is listening to for the duration of a dictation and
/// puts it back afterwards.
///
/// Two tiers, never both in the same moment:
///   1. Apple Events to Music/Spotify — precise, resumes only what we paused.
///   2. The system play/pause key — blind, so it is opt-in and only fires when
///      tier 1 found nothing to pause (otherwise it would undo tier 1's work).
///
/// Every Apple Event runs out of process; the recording path only ever enqueues
/// work and returns. See WHI-W2.
@MainActor
final class MediaPlaybackCoordinator {
	static let shared = MediaPlaybackCoordinator()

	/// Past this gap the user has moved on — silently restarting their music
	/// would be a surprise, not a courtesy.
	static let maxResumeGap: TimeInterval = 600

	private var pausedApps: [MediaApp] = []
	private var pausedAt: Date?
	private var usedMediaKey = false
	/// Serializes pause/resume so a resume can never overtake its own pause.
	private var work: Task<Void, Never>?

	private let tier1Enabled: @Sendable () -> Bool
	private let tier2Enabled: @Sendable () -> Bool
	private let runScript: @Sendable (String) -> String?
	// MainActor-isolated so assigning the AppKit-touching default below never
	// drops an isolation the compiler is tracking.
	private let sendMediaKey: @MainActor () -> Void
	private let now: @Sendable () -> Date

	init(
		tier1Enabled: @escaping @Sendable () -> Bool = { WhisperaSettings.pauseMediaWhileDictating },
		tier2Enabled: @escaping @Sendable () -> Bool = { WhisperaSettings.pauseMediaUsesMediaKey },
		// Closure literals rather than bare function references: an unapplied
		// declaration reference isn't inferred `@Sendable`.
		runScript: @escaping @Sendable (String) -> String? = { MediaPlaybackCoordinator.runOsascript($0) },
		sendMediaKey: @escaping @MainActor () -> Void = { MediaPlaybackCoordinator.postSystemPlayPause() },
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.tier1Enabled = tier1Enabled
		self.tier2Enabled = tier2Enabled
		self.runScript = runScript
		self.sendMediaKey = sendMediaKey
		self.now = now
	}

	// MARK: - Hooks

	/// Fire-and-forget: returns immediately, scripts run off the main actor.
	func pauseForDictation() {
		guard tier1Enabled() || tier2Enabled() else { return }
		enqueue { await self.performPause() }
	}

	/// Fire-and-forget. Safe to call from every stop/cancel path — the second and
	/// later calls for one dictation are no-ops.
	func resumeAfterDictation() {
		enqueue { await self.performResume() }
	}

	private func enqueue(_ operation: @escaping @Sendable @MainActor () async -> Void) {
		let previous = work
		work = Task { @MainActor in
			await previous?.value
			await operation()
		}
	}

	// MARK: - Pause / resume

	private func performPause() async {
		pausedApps = []
		usedMediaKey = false
		pausedAt = now()

		if tier1Enabled() {
			pausedApps = Self.pausedApps(in: await detached(Self.pauseScript))
			if !pausedApps.isEmpty {
				AppLogger.shared.audioManager.info(
					"Paused media for dictation: \(pausedApps.map(\.rawValue).joined(separator: ", "))")
			}
		}

		// Tier 2 is a blind toggle: firing it after tier 1 just paused something
		// would immediately resume that same player.
		if pausedApps.isEmpty, tier2Enabled() {
			sendMediaKey()
			usedMediaKey = true
			AppLogger.shared.audioManager.info("Sent system play/pause for dictation")
		}

		if pausedApps.isEmpty, !usedMediaKey { pausedAt = nil }
	}

	private func performResume() async {
		let apps = pausedApps
		let viaMediaKey = usedMediaKey
		let startedAt = pausedAt
		pausedApps = []
		usedMediaKey = false
		pausedAt = nil

		guard !apps.isEmpty || viaMediaKey, let startedAt else { return }

		guard now().timeIntervalSince(startedAt) <= Self.maxResumeGap else {
			AppLogger.shared.audioManager.info("Skipping media resume — dictation outran the resume window")
			return
		}

		if viaMediaKey {
			sendMediaKey()
			return
		}

		// The script re-reads `player state` and leaves anything already playing
		// alone, so a user who hit play mid-dictation keeps their own choice.
		_ = await detached(Self.resumeScript(for: apps))
		AppLogger.shared.audioManager.info(
			"Resumed media after dictation: \(apps.map(\.rawValue).joined(separator: ", "))")
	}

	private func detached(_ source: String) async -> String? {
		let run = runScript
		return await Task.detached { run(source) }.value
	}

	// MARK: - Scripts

	/// Guarded by `is running` so a stopped player is never launched just to be
	/// asked whether it is playing.
	static let pauseScript = """
		set pausedList to ""
		if application "Music" is running then
			tell application "Music"
				if player state is playing then
					pause
					set pausedList to pausedList & "music "
				end if
			end tell
		end if
		if application "Spotify" is running then
			tell application "Spotify"
				if player state is playing then
					pause
					set pausedList to pausedList & "spotify "
				end if
			end tell
		end if
		return pausedList
		"""

	static func resumeScript(for apps: [MediaApp]) -> String {
		apps.map { app in
			"""
			if application "\(app.rawValue)" is running then
				tell application "\(app.rawValue)"
					if player state is not playing then play
				end tell
			end if
			"""
		}.joined(separator: "\n")
	}

	static func pausedApps(in output: String?) -> [MediaApp] {
		guard let output else { return [] }
		let tokens = Set(output.split(whereSeparator: \.isWhitespace).map(String.init))
		return MediaApp.allCases.filter { tokens.contains($0.token) }
	}

	// MARK: - Transports

	/// Runs AppleScript out of process, so a first-run TCC prompt or a wedged
	/// media app blocks a throwaway subprocess instead of Whispera.
	nonisolated static func runOsascript(_ source: String) -> String? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", source]
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
		} catch {
			return nil
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { return nil }
		return String(data: data, encoding: .utf8)
	}

	/// NX_KEYTYPE_PLAY through a system-defined event — the same thing the
	/// keyboard's play/pause key posts, so every media app honours it.
	static func postSystemPlayPause() {
		let playKey = 16
		for keyState in [0xa00, 0xb00] {
			guard
				let event = NSEvent.otherEvent(
					with: .systemDefined,
					location: .zero,
					modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState)),
					timestamp: 0,
					windowNumber: 0,
					context: nil,
					subtype: 8,
					data1: (playKey << 16) | keyState,
					data2: -1)
			else { continue }
			event.cgEvent?.post(tap: .cghidEventTap)
		}
	}
}
