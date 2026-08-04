// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import CoreAudio
import Foundation

extension WhisperaSettings {
	private static let pauseMediaKey = "whisperaPauseMediaWhileDictating"

	/// Pause whatever the system is playing for the duration of a dictation.
	/// Default ON.
	static var pauseMediaWhileDictating: Bool {
		// `bool(forKey:)` can't express "absent means true", so read the object.
		get { UserDefaults.standard.object(forKey: pauseMediaKey) as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: pauseMediaKey) }
	}
}

/// One dictation's worth of paused media, and the rule for putting it back.
struct MediaPauseSession: Equatable, Sendable {
	let startedAt: Date

	/// Past this gap the user has moved on — silently restarting their music
	/// would be a surprise, not a courtesy.
	static let maxResumeGap: TimeInterval = 600

	func shouldResume(at date: Date) -> Bool {
		date.timeIntervalSince(startedAt) <= Self.maxResumeGap
	}
}

/// Pauses whatever the user is listening to for the duration of a dictation and
/// puts it back afterwards.
///
/// The mechanism is the system play/pause media key — the same event the
/// keyboard's play key and an AirPods tap post. macOS routes it to whichever app
/// it currently considers the Now Playing source, so browsers, players and
/// anything else that registers with the Now Playing router are all covered
/// without Whispera holding a single per-app permission.
///
/// The key is a toggle, so firing it blind would *start* playback when nothing
/// was playing. Both directions are therefore gated on whether some process
/// other than Whispera is actively rendering audio output (see
/// `otherProcessIsRenderingOutput`).
@MainActor
final class MediaPlaybackCoordinator {
	static let shared = MediaPlaybackCoordinator()

	private var session: MediaPauseSession?
	/// Serializes pause/resume so a resume can never overtake its own pause.
	private var work: Task<Void, Never>?

	private let isEnabled: @Sendable () -> Bool
	private let otherProcessIsPlayingOutput: @Sendable () -> Bool
	private let sendPlayPauseKey: @Sendable () -> Void
	private let resumeSettleSeconds: Double
	private let now: @Sendable () -> Date

	init(
		isEnabled: @escaping @Sendable () -> Bool = { WhisperaSettings.pauseMediaWhileDictating },
		// Closure literals rather than bare function references: an unapplied
		// declaration reference isn't inferred `@Sendable`.
		otherProcessIsPlayingOutput: @escaping @Sendable () -> Bool = {
			MediaPlaybackCoordinator.otherProcessIsRenderingOutput()
		},
		sendPlayPauseKey: @escaping @Sendable () -> Void = {
			MediaPlaybackCoordinator.postSystemPlayPause()
		},
		resumeSettleSeconds: Double = 0.6,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.isEnabled = isEnabled
		self.otherProcessIsPlayingOutput = otherProcessIsPlayingOutput
		self.sendPlayPauseKey = sendPlayPauseKey
		self.resumeSettleSeconds = resumeSettleSeconds
		self.now = now
	}

	// MARK: - Hooks

	/// Recording-start hook. Does not return until the pause has been decided and
	/// sent, so media cannot leak into the beginning (or all) of a short dictation.
	func pauseBeforeDictation() async {
		guard isEnabled() else { return }
		let previous = work
		let current = Task { @MainActor in
			await previous?.value
			await self.performPause()
		}
		work = current
		await current.value
	}

	/// Fire-and-forget. Safe to call from every stop/cancel path — the second and
	/// later calls for one dictation are no-ops.
	func resumeAfterDictation() {
		let previous = work
		work = Task { @MainActor in
			await previous?.value
			await self.performResume()
		}
	}

	/// Awaits all queued pause/resume work; exists for tests.
	func flush() async {
		await work?.value
	}

	// MARK: - Pause / resume

	private func performPause() async {
		session = nil
		guard otherProcessIsPlayingOutput() else {
			AppLogger.shared.audioManager.debug("Skipping media pause — nothing is playing")
			return
		}
		sendPlayPauseKey()
		session = MediaPauseSession(startedAt: now())
		AppLogger.shared.audioManager.info("Paused media for dictation")
	}

	private func performResume() async {
		guard let session else { return }
		self.session = nil

		guard session.shouldResume(at: now()) else {
			AppLogger.shared.audioManager.info(
				"Skipping media resume — dictation outran the resume window")
			return
		}

		// The gate already ignores our own process, so the stop chime cannot be read
		// as playback; the delay stays as cheap insurance against the paused app
		// still winding its IO down as the dictation ends.
		if resumeSettleSeconds > 0 {
			try? await Task.sleep(nanoseconds: UInt64(resumeSettleSeconds * 1_000_000_000))
		}

		// Playback that is running again is playback the user restarted during the
		// dictation. Sending the toggle now would stop it.
		guard !otherProcessIsPlayingOutput() else {
			AppLogger.shared.audioManager.info("Skipping media resume — playback is already running")
			return
		}
		sendPlayPauseKey()
		AppLogger.shared.audioManager.info("Resumed media after dictation")
	}

	// MARK: - Transport

	/// Whether some process *other than Whispera* is actively rendering audio
	/// output right now.
	///
	/// The device-level answer (`kAudioDevicePropertyDeviceIsRunningSomewhere`)
	/// cannot be used here: players and browsers keep the output device open for
	/// tens of seconds after the user pauses, so it reads "running" over silence
	/// and the play/pause toggle would *start* playback nobody asked for.
	/// `kAudioProcessPropertyIsRunningOutput` reports active IO per process
	/// instead, and skipping our own pid makes Whispera's own chimes structurally
	/// incapable of moving the answer in either direction.
	nonisolated static func otherProcessIsRenderingOutput() -> Bool {
		// Per-process audio state landed in macOS 14.4; below it the honest answer
		// is "unknown", and a skipped pause is a far cheaper failure than starting
		// playback out of silence.
		guard #available(macOS 14.4, *) else { return false }

		var listAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyProcessObjectList,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var listSize = UInt32(0)
		let sizeStatus = AudioObjectGetPropertyDataSize(
			AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize)
		guard sizeStatus == noErr, listSize > 0 else {
			AppLogger.shared.audioManager.error(
				"Could not size the audio process list: OSStatus \(sizeStatus)")
			return false
		}

		var processes = [AudioObjectID](
			repeating: AudioObjectID(kAudioObjectUnknown),
			count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
		let listStatus = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &processes)
		guard listStatus == noErr else {
			AppLogger.shared.audioManager.error(
				"Could not read the audio process list: OSStatus \(listStatus)")
			return false
		}

		let ownPID = getpid()
		var playingCount = 0
		for process in processes {
			// An unreadable pid could be our own, and counting it would risk the one
			// failure this gate exists to prevent.
			guard let pid = processPID(process), pid != ownPID else { continue }
			if processIsRunningOutput(process) { playingCount += 1 }
		}

		if playingCount > 1 {
			AppLogger.shared.audioManager.info(
				"\(playingCount) processes are playing audio — the media key only reaches the system's active Now Playing app"
			)
		}
		return playingCount > 0
	}

	private nonisolated static func processPID(_ process: AudioObjectID) -> pid_t? {
		var pid = pid_t(-1)
		var size = UInt32(MemoryLayout<pid_t>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioProcessPropertyPID,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr else {
			return nil
		}
		return pid
	}

	private nonisolated static func processIsRunningOutput(_ process: AudioObjectID) -> Bool {
		var isRunning = UInt32(0)
		var size = UInt32(MemoryLayout<UInt32>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioProcessPropertyIsRunningOutput,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &isRunning) == noErr else {
			return false
		}
		return isRunning != 0
	}

	/// NX_KEYTYPE_PLAY (16, from IOKit's ev_keymap.h) posted as a system-defined
	/// event, key down then key up. This is exactly what the hardware play/pause
	/// key emits, so it reaches the Now Playing router rather than any one app.
	nonisolated static func postSystemPlayPause() {
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
