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
///
/// `pausedPIDs` are the processes that stopped rendering output in direct
/// response to our key press — the only processes we have any claim to restart.
struct MediaPauseSession: Equatable, Sendable {
	let pausedPIDs: Set<pid_t>
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
/// The key is a toggle, and no public API answers "is media playing" beforehand:
/// measurement on real machines shows apps such as Parsec and Final Cut Pro
/// report `kAudioProcessPropertyIsRunningOutput` continuously while merely open,
/// so any "is anyone rendering output" gate is stuck true forever. Those constant
/// renderers do, however, cancel out of a before/after comparison. So this class
/// does not predict what the key will do — it presses once and then watches the
/// set of output-rendering processes change. A process that *disappears* is one we
/// paused; a process that *appears* is playback we started by accident, and the
/// same key is sent straight back to undo it.
///
/// Undoing a wrong press is fast but not silent, so the press itself is gated on a
/// second signal: a background observer samples the rendering set continuously and
/// remembers which processes it has watched *change* state. Ambient renderers never
/// change; real players start and stop. Only a process that is rendering now *and*
/// has been seen to toggle earns a press — see `plausiblePlayerIsRendering()`.
///
/// The honest limitation of that rule: if Whispera launches while music is already
/// playing, that process is rendering from the observer's very first sample and has
/// never been seen to change, so the first dictation will not pause it. The first
/// pause or resume the user performs by hand marks it, and every dictation after
/// that works. This is the trade we want — a missed pause is invisible, a phantom
/// start is not.
///
/// Explicit MediaRemote play/pause commands are not an option: since macOS 15.4
/// `MRMediaRemoteSendCommand` is entitlement-gated and returns true while doing
/// nothing. The toggle key is the only actuator there is.
///
/// The two edges of the signal are wildly asymmetric, which is the whole shape of
/// this class — see the timing constants on `init`.
@MainActor
final class MediaPlaybackCoordinator {
	static let shared = MediaPlaybackCoordinator()

	private(set) var session: MediaPauseSession?
	/// Serializes pause/resume so a resume can never overtake its own pause.
	private var work: Task<Void, Never>?
	private var observations: [pid_t: RenderObservation] = [:]
	private var hasObserved = false
	private var observer: Task<Void, Never>?
	private var observerGeneration = 0

	private let isEnabled: @Sendable () -> Bool
	private let renderingPIDs: @Sendable () -> Set<pid_t>
	private let processIsAlive: @Sendable (pid_t) -> Bool
	private let sendPlayPauseKey: @Sendable () -> Void
	private let fastPollInterval: Double
	private let fastWindow: Double
	private let slowPollInterval: Double
	private let slowWindow: Double
	private let observeInterval: Double
	private let now: @Sendable () -> Date

	/// What the observer knows about one process's output rendering.
	private struct RenderObservation {
		var isRendering: Bool
		/// True once we have seen this pid's rendering state differ from the
		/// previous sample. Ambient infrastructure never earns this.
		var everToggled: Bool
	}

	// Measured against real Spotify on macOS 26 by sampling
	// `kAudioProcessPropertyIsRunningOutput` per process:
	//   paused -> playing (appearance) takes 37-51 ms
	//   playing -> paused (disappearance) takes 2.0-2.3 s
	// A wrong press is audible, so the appearance check has to be tight and
	// cheap: 50 ms polls catch a real accidental start within two or three
	// samples and the whole blip stays under half a second. Confirming a pause
	// can only ever be slow, so it gets a lazy 250 ms cadence and a 3.5 s
	// ceiling — comfortably past the worst measured falling edge without
	// declaring failure early.
	// `observeInterval` drives the always-on toggle observer instead, where the
	// only requirement is to eventually notice a state change; a 2 s cadence
	// costs a sub-millisecond property read every other second.
	init(
		isEnabled: @escaping @Sendable () -> Bool = { WhisperaSettings.pauseMediaWhileDictating },
		// Closure literals rather than bare function references: an unapplied
		// declaration reference isn't inferred `@Sendable`.
		renderingPIDs: @escaping @Sendable () -> Set<pid_t> = {
			MediaPlaybackCoordinator.renderingProcessPIDs()
		},
		processIsAlive: @escaping @Sendable (pid_t) -> Bool = {
			MediaPlaybackCoordinator.processExists($0)
		},
		sendPlayPauseKey: @escaping @Sendable () -> Void = {
			MediaPlaybackCoordinator.postSystemPlayPause()
		},
		fastPollInterval: Double = 0.05,
		fastWindow: Double = 0.5,
		slowPollInterval: Double = 0.25,
		slowWindow: Double = 3.5,
		observeInterval: Double = 2.0,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.isEnabled = isEnabled
		self.renderingPIDs = renderingPIDs
		self.processIsAlive = processIsAlive
		self.sendPlayPauseKey = sendPlayPauseKey
		self.fastPollInterval = fastPollInterval
		self.fastWindow = fastWindow
		self.slowPollInterval = slowPollInterval
		self.slowWindow = slowWindow
		self.observeInterval = observeInterval
		self.now = now
	}

	// MARK: - Hooks

	/// Recording-start hook. Returns once the key has been sent, so media cannot
	/// leak into the beginning of a short dictation; the slower job of watching
	/// what the key actually did stays queued behind it and is what a later
	/// resume waits on.
	func pauseBeforeDictation() async {
		guard isEnabled() else {
			stopObserving()
			return
		}
		startObserving()
		let previous = work
		let pressed = Task { @MainActor () -> Set<pid_t>? in
			await previous?.value
			return self.sendPauseKey()
		}
		work = Task { @MainActor in
			guard let before = await pressed.value else { return }
			await self.classifyPause(before: before)
		}
		_ = await pressed.value
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

	// MARK: - Observer

	/// Samples the rendering set on a slow cadence for as long as the feature is
	/// on, so that by the time a dictation starts we already know which processes
	/// behave like players.
	///
	/// This exists because "is anything rendering output" is not a usable gate on
	/// real machines: measured over 30+ minutes on the owner's Mac, `parsecd`
	/// reported `kAudioProcessPropertyIsRunningOutput` true in 100% of samples with
	/// nothing playing, and Final Cut Pro did the same while merely open. Spotify,
	/// meanwhile, went true -> false -> true -> false across the same session. The
	/// discriminator is movement, not presence.
	private func startObserving() {
		guard observer == nil, observeInterval > 0 else { return }
		guard #available(macOS 14.4, *) else { return }

		observerGeneration += 1
		let generation = observerGeneration
		observer = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				guard let self, self.isEnabled() else { break }
				self.observeOnce()
				try? await Task.sleep(nanoseconds: UInt64(self.observeInterval * 1_000_000_000))
			}
			// Clearing the handle is what allows a restart, so only the loop that
			// still owns it may do so — a later loop must not be dropped by an
			// earlier one finishing.
			guard let self, self.observerGeneration == generation else { return }
			self.observer = nil
		}
	}

	private func stopObserving() {
		observer?.cancel()
		observer = nil
		observerGeneration += 1
	}

	/// One observation step: take a sample and fold it into `observations`.
	/// Called on the observer's cadence, and once more from the press gate so the
	/// decision is never made on a stale sample.
	func observeOnce() {
		record(sample: renderingPIDs())
	}

	private func record(sample: Set<pid_t>) {
		for pid in sample where observations[pid] == nil {
			// A pid already rendering at the very first sample may have been
			// rendering for hours — we did not witness its start, so it is not
			// toggled. A pid that shows up later did start while we watched.
			observations[pid] = RenderObservation(isRendering: true, everToggled: hasObserved)
		}

		for (pid, observation) in observations {
			let isRendering = sample.contains(pid)
			guard isRendering != observation.isRendering else { continue }
			observations[pid] = RenderObservation(isRendering: isRendering, everToggled: true)
		}

		// Keep the map bounded: a pid that is gone entirely can never toggle again,
		// and pids are recycled.
		for (pid, observation) in observations
		where !observation.isRendering && !processIsAlive(pid) {
			observations.removeValue(forKey: pid)
		}

		hasObserved = true
	}

	/// True when something rendering output right now has also been seen to change
	/// state — the only evidence we have that a press would reach a real player
	/// rather than start one.
	func plausiblePlayerIsRendering() -> Bool {
		observations.values.contains { $0.isRendering && $0.everToggled }
	}

	// MARK: - Pause

	/// Reads the baseline and presses the key. Returns the baseline, or nil when
	/// no key was sent.
	private func sendPauseKey() -> Set<pid_t>? {
		session = nil
		// Per-process audio state landed in macOS 14.4. Without it there is no
		// baseline to compare against, so the honest move is to leave the user's
		// audio alone entirely rather than fire a blind toggle.
		guard #available(macOS 14.4, *) else { return nil }

		let before = renderingPIDs()
		record(sample: before)
		guard plausiblePlayerIsRendering() else {
			// The common case on a machine with ambient renderers and nothing
			// playing, so it must not spam the log at info.
			AppLogger.shared.audioManager.debug(
				"Skipping media pause — nothing that behaves like a player is rendering, the key could only start playback"
			)
			return nil
		}

		sendPlayPauseKey()
		return before
	}

	/// Watches what the key did and records a session only if it actually paused
	/// something.
	private func classifyPause(before: Set<pid_t>) async {
		let appeared: (Set<pid_t>) -> Bool = { !$0.subtracting(before).isEmpty }
		let disappeared: (Set<pid_t>) -> Bool = { !before.subtracting($0).isEmpty }

		// Appearance first and on the tight cadence: a wrong press is audible, and
		// the rising edge is ~40 ms, so this either fires almost immediately or not
		// at all. Waiting out the slow disappearance window before checking would
		// leave unwanted playback running for seconds.
		if let after = await poll(every: fastPollInterval, upTo: fastWindow, until: appeared) {
			let started = after.subtracting(before)
			sendPlayPauseKey()
			AppLogger.shared.audioManager.info(
				"Media key started playback that was not running (pids \(started.sorted())) — sending it back to stop"
			)
			return
		}

		guard let after = await poll(every: slowPollInterval, upTo: slowWindow, until: disappeared) else {
			// Pressing again here would be a coin flip: we do not know whether the
			// key reached nothing or reached an app that ignored it.
			AppLogger.shared.audioManager.info(
				"Media key stopped nothing within \(slowWindow)s — nothing to resume")
			return
		}

		let stopped = before.subtracting(after)
		session = MediaPauseSession(pausedPIDs: stopped, startedAt: now())
		AppLogger.shared.audioManager.info("Paused media for dictation: pids \(stopped.sorted())")

		// One press reaches only the system's active Now Playing app, by OS design.
		// Pressing again would resume the app we just paused, so the honest outcome
		// for the rest is a log.
		if !after.isEmpty {
			AppLogger.shared.audioManager.info(
				"\(after.count) other process(es) are still rendering output — the media key only reaches the system's active Now Playing app"
			)
		}
	}

	// MARK: - Resume

	private func performResume() async {
		guard let session else { return }
		self.session = nil

		guard session.shouldResume(at: now()) else {
			AppLogger.shared.audioManager.info(
				"Skipping media resume — dictation outran the resume window")
			return
		}

		let before = renderingPIDs()
		// A session exists only because we watched these pids stop, so one of them
		// rendering again is playback the user restarted by hand; the toggle would
		// stop it.
		guard session.pausedPIDs.isDisjoint(with: before) else {
			AppLogger.shared.audioManager.info(
				"Skipping media resume — the user restarted playback themselves")
			return
		}

		sendPlayPauseKey()

		// Resume is verified on the rising edge only, which is the fast one.
		let appeared: (Set<pid_t>) -> Bool = { !$0.subtracting(before).isEmpty }
		guard let after = await poll(every: fastPollInterval, upTo: fastWindow, until: appeared) else {
			AppLogger.shared.audioManager.info(
				"Resume key did not bring back what we paused — leaving playback alone")
			return
		}

		let started = after.subtracting(before)
		if started.isDisjoint(with: session.pausedPIDs) {
			sendPlayPauseKey()
			AppLogger.shared.audioManager.info(
				"Resume key started a different app (pids \(started.sorted())) — sending it back to stop"
			)
		} else {
			AppLogger.shared.audioManager.info("Resumed media after dictation")
		}
	}

	// MARK: - Delta

	/// Samples the rendering-pid set every `interval` for at most `window` seconds
	/// and returns the first sample that satisfies `isMatch`, or nil.
	private func poll(
		every interval: Double,
		upTo window: Double,
		until isMatch: (Set<pid_t>) -> Bool
	) async -> Set<pid_t>? {
		guard interval > 0, window > 0 else { return nil }
		let attempts = max(1, Int((window / interval).rounded(.up)))
		for _ in 0..<attempts {
			try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
			let current = renderingPIDs()
			if isMatch(current) { return current }
		}
		return nil
	}

	// MARK: - Transport

	/// The pids of every process *other than Whispera* rendering audio output
	/// right now.
	///
	/// The device-level answer (`kAudioDevicePropertyDeviceIsRunningSomewhere`)
	/// is useless here: it stays "running" over silence for tens of seconds after a
	/// pause. `kAudioProcessPropertyIsRunningOutput` reports active IO per process
	/// instead, and skipping our own pid makes Whispera's own chimes structurally
	/// incapable of moving any delta.
	nonisolated static func renderingProcessPIDs() -> Set<pid_t> {
		guard #available(macOS 14.4, *) else { return [] }

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
			return []
		}

		var processes = [AudioObjectID](
			repeating: AudioObjectID(kAudioObjectUnknown),
			count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
		let listStatus = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &processes)
		guard listStatus == noErr else {
			AppLogger.shared.audioManager.error(
				"Could not read the audio process list: OSStatus \(listStatus)")
			return []
		}

		let ownPID = getpid()
		var playing = Set<pid_t>()
		for process in processes {
			guard let pid = processPID(process), pid != ownPID else { continue }
			if processIsRunningOutput(process) { playing.insert(pid) }
		}
		return playing
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

	/// Signal 0 performs the permission and existence checks without delivering
	/// anything; EPERM means the process is alive but out of our reach.
	nonisolated static func processExists(_ pid: pid_t) -> Bool {
		kill(pid, 0) == 0 || errno == EPERM
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
