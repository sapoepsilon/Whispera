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
/// was playing. Both directions are therefore gated on CoreAudio's read of the
/// default output device (see `defaultOutputDeviceIsRunning`).
@MainActor
final class MediaPlaybackCoordinator {
	static let shared = MediaPlaybackCoordinator()

	private var session: MediaPauseSession?
	/// Serializes pause/resume so a resume can never overtake its own pause.
	private var work: Task<Void, Never>?

	private let isEnabled: @Sendable () -> Bool
	private let isOutputRunning: @Sendable () -> Bool
	private let sendPlayPauseKey: @Sendable () -> Void
	private let resumeSettleSeconds: Double
	private let now: @Sendable () -> Date

	init(
		isEnabled: @escaping @Sendable () -> Bool = { WhisperaSettings.pauseMediaWhileDictating },
		// Closure literals rather than bare function references: an unapplied
		// declaration reference isn't inferred `@Sendable`.
		isOutputRunning: @escaping @Sendable () -> Bool = {
			MediaPlaybackCoordinator.defaultOutputDeviceIsRunning()
		},
		sendPlayPauseKey: @escaping @Sendable () -> Void = {
			MediaPlaybackCoordinator.postSystemPlayPause()
		},
		resumeSettleSeconds: Double = 0.6,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.isEnabled = isEnabled
		self.isOutputRunning = isOutputRunning
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
		guard isOutputRunning() else {
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

		// Whispera's own stop chime and the HAL's tail both keep the device
		// "running" for a moment after a dictation ends; sampling immediately would
		// read our own sound as the user having resumed playback themselves.
		if resumeSettleSeconds > 0 {
			try? await Task.sleep(nanoseconds: UInt64(resumeSettleSeconds * 1_000_000_000))
		}

		// Playback that is running again is playback the user restarted during the
		// dictation. Sending the toggle now would stop it.
		guard !isOutputRunning() else {
			AppLogger.shared.audioManager.info("Skipping media resume — playback is already running")
			return
		}
		sendPlayPauseKey()
		AppLogger.shared.audioManager.info("Resumed media after dictation")
	}

	// MARK: - Transport

	/// Whether the current default output device has IO running anywhere on the
	/// system — the only signal macOS offers about "is something playing" that
	/// costs no permission at all.
	///
	/// It is honestly approximate. It describes the device, not an app, so any
	/// system sound counts; and several Bluetooth outputs keep their stream open
	/// after playback stops (or spin it up before it starts), so the answer can
	/// lag reality by seconds on those. Both failure modes are one-sided by
	/// design: a false "running" only costs a skipped pause or a skipped resume,
	/// never an unwanted toggle.
	nonisolated static func defaultOutputDeviceIsRunning() -> Bool {
		var deviceID = AudioDeviceID(kAudioObjectUnknown)
		var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
		var deviceAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultOutputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		let deviceStatus = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &deviceID)
		guard deviceStatus == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
			AppLogger.shared.audioManager.error(
				"Could not read the default output device: OSStatus \(deviceStatus)")
			return false
		}

		var isRunning = UInt32(0)
		var runningSize = UInt32(MemoryLayout<UInt32>.size)
		var runningAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		let runningStatus = AudioObjectGetPropertyData(
			deviceID, &runningAddress, 0, nil, &runningSize, &isRunning)
		guard runningStatus == noErr else {
			AppLogger.shared.audioManager.error(
				"Could not read output device activity: OSStatus \(runningStatus)")
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
