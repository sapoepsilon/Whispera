// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import CoreAudio
import Foundation

/// Silences browsers that refused tab scripting, for the duration of one
/// dictation, by attaching a muting CoreAudio process tap to every one of their
/// processes that is currently sending audio to the hardware.
///
/// This is the only permission-free fallback that is safe by construction: a
/// tap can just remove sound, so it can never start playback the user did not
/// begin — unlike a media key or a `play` command. Nothing is tapped unless the
/// process is audibly playing right now, and nothing at all happens to a
/// browser that is silent.
///
/// Called from the coordinator's detached tasks, so all state lives behind a
/// lock.
final class BrowserAudioMuter: @unchecked Sendable {
	static let shared = BrowserAudioMuter()

	private struct AudibleProcess {
		let objectID: AudioObjectID
		let bundleID: String
	}

	private let lock = NSLock()
	private var taps: [AudioObjectID] = []
	private var loggedUnsupportedSystem = false

	/// Mutes every target that is audibly playing and can be tapped.
	///
	/// - Returns: `muted` — targets now silenced; `audibleButUnmutable` — targets
	///   we proved are playing but could not silence (no system-audio permission,
	///   or the tap was refused). A silent target appears in neither list because
	///   there is nothing to do about it.
	func muteAudiblyPlaying(_ targets: [MediaTarget]) -> (
		muted: [MediaTarget], audibleButUnmutable: [MediaTarget]
	) {
		guard !targets.isEmpty else { return ([], []) }
		guard #available(macOS 14.4, *) else {
			logUnsupportedSystemOnce()
			return ([], [])
		}

		let audible = Self.audibleProcesses()
		guard !audible.isEmpty else { return ([], []) }

		var muted: [MediaTarget] = []
		var unmutable: [MediaTarget] = []
		var created: [AudioObjectID] = []

		for target in targets {
			let prefixes = Self.bundleIDPrefixes(for: target)
			let matches = audible.filter { process in
				prefixes.contains { process.bundleID.hasPrefix($0) }
			}
			guard !matches.isEmpty else { continue }

			let tapIDs = matches.compactMap { Self.createMuteTap(for: $0.objectID, target: target) }
			if tapIDs.isEmpty {
				unmutable.append(target)
			} else {
				created.append(contentsOf: tapIDs)
				muted.append(target)
			}
		}

		if !created.isEmpty {
			lock.withLock { taps.append(contentsOf: created) }
		}
		return (muted, unmutable)
	}

	/// Destroys every tap this muter created. Idempotent, and safe to call when
	/// nothing was ever muted.
	func unmuteAll() {
		let pending: [AudioObjectID] = lock.withLock {
			let current = taps
			taps = []
			return current
		}
		guard !pending.isEmpty else { return }
		// A tap can only exist on a system that was able to create one.
		guard #available(macOS 14.4, *) else { return }

		for tap in pending {
			let status = AudioHardwareDestroyProcessTap(tap)
			if status != noErr {
				AppLogger.shared.audioManager.error(
					"Failed to destroy browser mute tap \(tap): OSStatus \(status)")
			}
		}
		AppLogger.shared.audioManager.info("Unmuted \(pending.count) browser process tap(s)")
	}

	private func logUnsupportedSystemOnce() {
		let shouldLog: Bool = lock.withLock {
			guard !loggedUnsupportedSystem else { return false }
			loggedUnsupportedSystem = true
			return true
		}
		guard shouldLog else { return }
		AppLogger.shared.audioManager.info(
			"Browser audio muting needs macOS 14.4 or later — blocked browsers keep playing")
	}

	// MARK: - Matching

	/// Bundle-id prefixes, matched by prefix so helper and renderer processes
	/// come along. Safari itself never plays the audio: WebKit hands media
	/// playback to a separate GPU process, which is its own CoreAudio client.
	private static func bundleIDPrefixes(for target: MediaTarget) -> [String] {
		switch target {
		case .safari: return ["com.apple.Safari", "com.apple.WebKit.GPU"]
		case .chrome: return ["com.google.Chrome"]
		case .edge: return ["com.microsoft.edgemac"]
		case .brave: return ["com.brave.Browser"]
		case .music, .spotify: return []
		}
	}

	// MARK: - CoreAudio

	@available(macOS 14.4, *)
	private static func audibleProcesses() -> [AudibleProcess] {
		processObjectIDs().compactMap { objectID in
			guard isRunningOutput(objectID), let bundleID = bundleID(of: objectID) else { return nil }
			return AudibleProcess(objectID: objectID, bundleID: bundleID)
		}
	}

	private static func processObjectIDs() -> [AudioObjectID] {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyProcessObjectList,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)

		var size: UInt32 = 0
		var status = AudioObjectGetPropertyDataSize(
			AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
		guard status == noErr else {
			AppLogger.shared.audioManager.error(
				"Failed to size the CoreAudio process list: OSStatus \(status)")
			return []
		}

		let count = Int(size) / MemoryLayout<AudioObjectID>.size
		guard count > 0 else { return [] }

		var objectIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
		status = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
		guard status == noErr else {
			AppLogger.shared.audioManager.error(
				"Failed to read the CoreAudio process list: OSStatus \(status)")
			return []
		}
		return objectIDs
	}

	private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioProcessPropertyIsRunningOutput,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)

		var value: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
		guard status == noErr else { return false }
		return value != 0
	}

	private static func bundleID(of objectID: AudioObjectID) -> String? {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioProcessPropertyBundleID,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)

		// The property hands back a +1 CFString; letting ARC own the optional
		// slot balances that release when this scope ends.
		var value: CFString?
		var size = UInt32(MemoryLayout<CFString?>.size)
		let status = withUnsafeMutablePointer(to: &value) { pointer in
			AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
		}
		guard status == noErr, let value else { return nil }
		return value as String
	}

	@available(macOS 14.4, *)
	private static func createMuteTap(for process: AudioObjectID, target: MediaTarget) -> AudioObjectID? {
		let description = CATapDescription(stereoMixdownOfProcesses: [process])
		description.name = "Whispera dictation mute"
		description.isPrivate = true
		// Not `.mutedWhenTapped`: that one only silences while an audio client is
		// reading the tap, and we never read it — we create the tap purely for its
		// mute. `.muted` silences for the tap's whole lifetime.
		description.muteBehavior = .muted

		var tapID = AudioObjectID(kAudioObjectUnknown)
		let status = AudioHardwareCreateProcessTap(description, &tapID)
		guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
			AppLogger.shared.audioManager.error(
				"Failed to mute \(target.rawValue) process \(process): OSStatus \(status)")
			return nil
		}
		return tapID
	}
}
