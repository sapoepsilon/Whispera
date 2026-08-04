// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import CoreAudio
import Foundation

extension WhisperaSettings {
	// The key still says "pause" because that is what shipped; renaming it would
	// silently reset everyone who had turned the feature off.
	private static let muteAudioKey = "whisperaPauseMediaWhileDictating"

	/// Mute the system output device for the duration of a dictation. Default ON.
	static var muteAudioWhileDictating: Bool {
		// `bool(forKey:)` can't express "absent means true", so read the object.
		get { UserDefaults.standard.object(forKey: muteAudioKey) as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: muteAudioKey) }
	}
}

/// Mutes the system's default output device while a dictation is running and
/// unmutes it afterwards.
///
/// This replaces an earlier design that pressed the system play/pause media key.
/// That key reaches only whichever app macOS currently considers the Now Playing
/// source, so with two players running it paused one of them, then the other, and
/// resumed neither. Muting the output device is unconditional: it silences
/// everything the machine is playing, needs no per-app permission, and does not
/// disturb anyone's playback position.
///
/// Measured on the owner's Mac with AirPods Max (Bluetooth — the awkward device
/// class) as the default output:
///   - `kAudioDevicePropertyMute` in `kAudioDevicePropertyScopeOutput`:
///     present and settable; set to 1 and back to 0 both returned noErr and read
///     back correctly, with playback continuing silently in between.
///   - `kAudioDevicePropertyVolumeScalar` was NOT readable on that same device.
/// So do not add a "drop the volume instead" fallback — on a real Bluetooth
/// device there is no volume to read or restore, and a half-working fallback that
/// leaves the user at zero volume is worse than doing nothing.
///
/// Leaving a user muted is the only serious failure mode here, so restoring is
/// defended three ways: every dictation stop/cancel/error path calls
/// `restoreAfterDictation()`, a watchdog unmutes after `maxMuteSeconds`, and
/// `NSApplication.willTerminateNotification` unmutes on quit.
@MainActor
final class SystemAudioMuter {
	static let shared = SystemAudioMuter()

	/// The device we muted, and only if *we* muted it. Nil means there is nothing
	/// to put back — including the case where the user had already muted the
	/// device themselves, which we must never undo.
	private(set) var mutedDevice: AudioDeviceID?
	private var mutedAt: Date?
	private var watchdog: Task<Void, Never>?

	private let isEnabled: @Sendable () -> Bool
	private let defaultOutputDevice: @Sendable () -> AudioDeviceID?
	private let muteIsSettable: @Sendable (AudioDeviceID) -> Bool
	private let readMute: @Sendable (AudioDeviceID) -> Bool?
	private let writeMute: @Sendable (AudioDeviceID, Bool) -> Bool
	private let maxMuteSeconds: Double
	private var terminationObserver: (any NSObjectProtocol)?

	init(
		isEnabled: @escaping @Sendable () -> Bool = { WhisperaSettings.muteAudioWhileDictating },
		// Closure literals rather than bare function references: an unapplied
		// declaration reference isn't inferred `@Sendable`.
		defaultOutputDevice: @escaping @Sendable () -> AudioDeviceID? = {
			SystemAudioMuter.systemDefaultOutputDevice()
		},
		muteIsSettable: @escaping @Sendable (AudioDeviceID) -> Bool = {
			SystemAudioMuter.muteIsSettable(on: $0)
		},
		readMute: @escaping @Sendable (AudioDeviceID) -> Bool? = {
			SystemAudioMuter.readMute(on: $0)
		},
		writeMute: @escaping @Sendable (AudioDeviceID, Bool) -> Bool = {
			SystemAudioMuter.writeMute($1, on: $0)
		},
		maxMuteSeconds: Double = 600,
		observesTermination: Bool = true
	) {
		self.isEnabled = isEnabled
		self.defaultOutputDevice = defaultOutputDevice
		self.muteIsSettable = muteIsSettable
		self.readMute = readMute
		self.writeMute = writeMute
		self.maxMuteSeconds = maxMuteSeconds

		guard observesTermination else { return }
		terminationObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.willTerminateNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.mutedDevice != nil else { return }
				AppLogger.shared.audioManager.info("Restoring system audio before quitting")
				self.restoreAfterDictation()
			}
		}
	}

	deinit {
		if let terminationObserver {
			NotificationCenter.default.removeObserver(terminationObserver)
		}
	}

	// MARK: - Hooks

	/// Recording-start hook. Synchronous: writing a CoreAudio property is a single
	/// immediate call, so dictation never waits on us.
	func muteForDictation() {
		guard isEnabled() else { return }
		guard mutedDevice == nil else { return }

		guard let device = defaultOutputDevice() else {
			AppLogger.shared.audioManager.info(
				"Skipping dictation mute — no default output device")
			return
		}
		guard muteIsSettable(device) else {
			// Aggregate and some virtual devices expose no writable mute at all.
			AppLogger.shared.audioManager.info(
				"Skipping dictation mute — output device \(device) has no settable mute")
			return
		}
		guard let alreadyMuted = readMute(device) else {
			AppLogger.shared.audioManager.info(
				"Skipping dictation mute — could not read the mute state of device \(device)")
			return
		}
		guard !alreadyMuted else {
			// The user muted it themselves; unmuting later would be us turning their
			// sound on for them.
			AppLogger.shared.audioManager.debug(
				"Skipping dictation mute — output device \(device) is already muted")
			return
		}
		guard writeMute(device, true) else {
			AppLogger.shared.audioManager.error(
				"Could not mute output device \(device) for dictation")
			return
		}

		mutedDevice = device
		mutedAt = Date()
		startWatchdog()
		AppLogger.shared.audioManager.info("Muted output device \(device) for dictation")
	}

	/// Safe to call from every stop/cancel/error path — the second and later calls
	/// for one dictation are no-ops.
	func restoreAfterDictation() {
		watchdog?.cancel()
		watchdog = nil

		guard let device = mutedDevice else { return }
		mutedDevice = nil
		mutedAt = nil

		guard writeMute(device, false) else {
			// The likeliest cause is that the device went away mid-dictation, e.g.
			// AirPods disconnecting; whatever replaced it was never muted by us.
			AppLogger.shared.audioManager.info(
				"Could not unmute output device \(device) — it is probably gone")
			return
		}
		AppLogger.shared.audioManager.info("Restored output device \(device) after dictation")
	}

	/// Awaits the watchdog; exists for tests.
	func flush() async {
		await watchdog?.value
	}

	// MARK: - Watchdog

	/// Last line of defence: if no stop path ever fires — a hung transcription, a
	/// crash in a caller — the user gets their audio back anyway.
	private func startWatchdog() {
		watchdog?.cancel()
		guard maxMuteSeconds > 0 else { return }
		let seconds = maxMuteSeconds
		watchdog = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			guard !Task.isCancelled, let self, self.mutedDevice != nil else { return }
			AppLogger.shared.audioManager.info(
				"Dictation mute outlived \(seconds)s — restoring system audio")
			self.restoreAfterDictation()
		}
	}

	// MARK: - CoreAudio

	private nonisolated static func muteAddress() -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyMute,
			mScope: kAudioDevicePropertyScopeOutput,
			mElement: kAudioObjectPropertyElementMain
		)
	}

	nonisolated static func systemDefaultOutputDevice() -> AudioDeviceID? {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultOutputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var device = AudioDeviceID(kAudioObjectUnknown)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		let status = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
		guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
		return device
	}

	nonisolated static func muteIsSettable(on device: AudioDeviceID) -> Bool {
		var address = muteAddress()
		guard AudioObjectHasProperty(device, &address) else { return false }
		var settable = DarwinBoolean(false)
		guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else {
			return false
		}
		return settable.boolValue
	}

	/// Nil when the property could not be read at all, which is a different answer
	/// from "not muted" and must not be treated as one.
	nonisolated static func readMute(on device: AudioDeviceID) -> Bool? {
		var address = muteAddress()
		var value = UInt32(0)
		var size = UInt32(MemoryLayout<UInt32>.size)
		guard
			AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
		else { return nil }
		return value != 0
	}

	nonisolated static func writeMute(_ muted: Bool, on device: AudioDeviceID) -> Bool {
		var address = muteAddress()
		var value = UInt32(muted ? 1 : 0)
		let size = UInt32(MemoryLayout<UInt32>.size)
		return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
	}
}
