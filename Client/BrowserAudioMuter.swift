// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import CoreAudio
import Foundation

/// Silences whatever is audibly playing that we could not pause
/// deterministically — a browser that refused tab scripting, a browser whose
/// script we could not run at all, an app we have no AppleScript dictionary for
/// — for the duration of one dictation, by attaching a muting CoreAudio process
/// tap to every one of its processes that is currently feeding the hardware.
///
/// This is the only permission-free intervention that is safe by construction:
/// a tap can just remove sound, so it can never start playback the user did not
/// begin — unlike a media key or a `play` command. Nothing is tapped unless the
/// process is sending audio right now, so an app that is idle or already paused
/// is never touched.
///
/// Every tap here is one this object created, and `unmuteAll` destroys exactly
/// those: by construction it can never lift a mute that belongs to anything
/// else.
///
/// Called from the coordinator's detached tasks, so all state lives behind a
/// lock.
final class BrowserAudioMuter: @unchecked Sendable {
	static let shared = BrowserAudioMuter()

	private struct AudibleProcess {
		let objectID: AudioObjectID
		let pid: pid_t?
		let bundleID: String
	}
	private struct TapRecord {
		let tapID: AudioObjectID
		let processID: AudioObjectID
	}

	private let lock = NSLock()
	private var taps: [TapRecord] = []
	/// Process objects this session already tapped, so nothing is ever tapped
	/// twice and a second pass can tell "already muted" apart from "cannot mute".
	private var tappedProcesses: Set<AudioObjectID> = []
	private var loggedUnsupportedSystem = false

	/// Mutes every named target that is audibly playing and can be tapped.
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

		for target in targets {
			let prefixes = Self.bundleIDPrefixes(for: target)
			let matches = audible.filter { process in
				prefixes.contains { process.bundleID.hasPrefix($0) }
			}
			guard !matches.isEmpty else { continue }

			let outcomes = matches.map { mute(process: $0.objectID, label: target.rawValue) }
			if outcomes.allSatisfy({ $0 }) {
				muted.append(target)
			} else {
				// Even one surviving renderer can keep the tab audible. Report the
				// whole browser as unresolved instead of overstating partial success.
				unmutable.append(target)
			}
		}
		return (muted, unmutable)
	}

	/// Mutes everything else that is still audible — apps we cannot address by
	/// name at all: Firefox, VLC, IINA, Podcasts, a browser variant we have no
	/// dictionary for. Whatever the deterministic sweep paused has already
	/// stopped feeding the hardware by now, so it excludes itself here.
	///
	/// - Returns: bundle ids, for logging only. There is no recovery to offer for
	///   an app we cannot name, so nothing here is ever put in front of the user.
	func muteRemainingAudibleProcesses(excludingBrowsers: Bool = false) -> (
		muted: [String], unmutable: [String]
	) {
		guard #available(macOS 14.4, *) else {
			logUnsupportedSystemOnce()
			return ([], [])
		}

		let ownPID = ProcessInfo.processInfo.processIdentifier
		var muted: [String] = []
		var unmutable: [String] = []

		for process in Self.audibleProcesses() {
			// A process whose pid we cannot read might be Whispera itself, and
			// muting our own output would take the dictation's own feedback away.
			guard let pid = process.pid, pid != ownPID else { continue }
			guard !Self.isProtectedFromMuting(process.bundleID) else { continue }
			guard !excludingBrowsers || !Self.isBrowser(process.bundleID) else { continue }
			guard !isTapped(process.objectID) else { continue }

			if mute(process: process.objectID, label: process.bundleID) {
				muted.append(process.bundleID)
			} else {
				unmutable.append(process.bundleID)
			}
		}
		return (Self.unique(muted), Self.unique(unmutable))
	}

	/// Destroys every tap this muter created, and only those. Idempotent, and
	/// safe to call when nothing was ever muted.
	func unmuteAll() {
		let pending: [TapRecord] = lock.withLock {
			let current = taps
			taps = []
			tappedProcesses = []
			return current
		}
		guard !pending.isEmpty else { return }
		// A tap can only exist on a system that was able to create one.
		guard #available(macOS 14.4, *) else { return }

		var failed: [TapRecord] = []
		for record in pending {
			let status = AudioHardwareDestroyProcessTap(record.tapID)
			if status != noErr {
				AppLogger.shared.audioManager.error(
					"Failed to destroy mute tap \(record.tapID): OSStatus \(status)")
				failed.append(record)
			}
		}
		if !failed.isEmpty {
			// A failed destruction means the process may still be muted. Retain
			// ownership so the next idempotent resume/cleanup call retries it.
			lock.withLock {
				taps.append(contentsOf: failed)
				tappedProcesses.formUnion(failed.map(\.processID))
			}
		}
		AppLogger.shared.audioManager.info(
			"Unmuted \(pending.count - failed.count) process tap(s); \(failed.count) pending retry")
	}

	/// - Returns: true when the process ends up muted, either by this call or by
	///   an earlier one in the same dictation.
	@available(macOS 14.4, *)
	private func mute(process: AudioObjectID, label: String) -> Bool {
		let claimed = lock.withLock { tappedProcesses.insert(process).inserted }
		guard claimed else { return true }

		guard let tap = Self.createMuteTap(for: process, label: label) else {
			// Released again so the next dictation retries instead of treating a
			// one-off failure as a standing mute.
			lock.withLock { _ = tappedProcesses.remove(process) }
			return false
		}
		lock.withLock { taps.append(TapRecord(tapID: tap, processID: process)) }
		return true
	}

	private func isTapped(_ process: AudioObjectID) -> Bool {
		lock.withLock { tappedProcesses.contains(process) }
	}

	private func logUnsupportedSystemOnce() {
		let shouldLog: Bool = lock.withLock {
			guard !loggedUnsupportedSystem else { return false }
			loggedUnsupportedSystem = true
			return true
		}
		guard shouldLog else { return }
		AppLogger.shared.audioManager.info(
			"Audio muting needs macOS 14.4 or later — media we could not pause keeps playing")
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

	/// Off limits to the general pass: the audio plumbing itself, and anything
	/// that speaks to the user. Silencing a screen reader for the length of a
	/// dictation would take away the very feedback the user runs it by.
	private static let protectedBundleIDPrefixes = [
		"com.apple.audio",
		"com.apple.speech",
		"com.apple.VoiceOver",
		"com.apple.accessibility",
	]

	private static func isProtectedFromMuting(_ bundleID: String) -> Bool {
		protectedBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
	}

	/// Used only when the user explicitly opted browser tabs out while leaving
	/// general media pausing on. The default path includes browsers.
	private static let browserBundleIDPrefixes = [
		"com.apple.Safari", "com.apple.WebKit", "com.google.Chrome",
		"com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
		"company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
	]

	private static func isBrowser(_ bundleID: String) -> Bool {
		browserBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
	}

	/// One app can own several audible processes; the log wants the app once.
	private static func unique(_ bundleIDs: [String]) -> [String] {
		var seen: Set<String> = []
		return bundleIDs.filter { seen.insert($0).inserted }
	}

	// MARK: - CoreAudio

	@available(macOS 14.4, *)
	private static func audibleProcesses() -> [AudibleProcess] {
		processObjectIDs().compactMap { objectID in
			guard isRunningOutput(objectID), let bundleID = bundleID(of: objectID) else { return nil }
			return AudibleProcess(objectID: objectID, pid: pid(of: objectID), bundleID: bundleID)
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

	private static func pid(of objectID: AudioObjectID) -> pid_t? {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioProcessPropertyPID,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)

		var value: pid_t = -1
		var size = UInt32(MemoryLayout<pid_t>.size)
		let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
		guard status == noErr else { return nil }
		return value
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
	private static func createMuteTap(for process: AudioObjectID, label: String) -> AudioObjectID? {
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
				"Failed to mute \(label) process \(process): OSStatus \(status)")
			return nil
		}
		return tapID
	}
}
