// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

extension WhisperaSettings {
	private static let pauseMediaKey = "whisperaPauseMediaWhileDictating"
	private static let pauseBrowserMediaKey = "whisperaPauseBrowserMediaWhileDictating"

	/// Pause Music/Spotify through Apple Events. Default ON.
	static var pauseMediaWhileDictating: Bool {
		// `bool(forKey:)` can't express "absent means true", so read the object.
		get { UserDefaults.standard.object(forKey: pauseMediaKey) as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: pauseMediaKey) }
	}

	/// Also pause playing tabs in the major browsers. Default ON; only takes
	/// effect while the master toggle above is on.
	static var pauseBrowserMediaWhileDictating: Bool {
		get { UserDefaults.standard.object(forKey: pauseBrowserMediaKey) as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: pauseBrowserMediaKey) }
	}
}

extension Notification.Name {
	/// A browser we could not pause is still audible, and muting it failed too.
	/// Carries a ready-made recovery message so the UI layer never has to know
	/// about AppleScript.
	static let browserMediaPauseBlocked = Notification.Name("BrowserMediaPauseBlocked")
}

/// A media source Whispera can pause deterministically — by reading real player
/// state, never by guessing. Raw value is the AppleScript application name.
enum MediaTarget: String, CaseIterable, Sendable {
	case music = "Music"
	case spotify = "Spotify"
	case safari = "Safari"
	case chrome = "Google Chrome"
	case edge = "Microsoft Edge"
	case brave = "Brave Browser"

	/// Token the pause script echoes back so we know exactly what we paused.
	var token: String {
		switch self {
		case .music: return "music"
		case .spotify: return "spotify"
		case .safari: return "safari"
		case .chrome: return "chrome"
		case .edge: return "edge"
		case .brave: return "brave"
		}
	}

	var isBrowser: Bool {
		switch self {
		case .music, .spotify: return false
		case .safari, .chrome, .edge, .brave: return true
		}
	}
}

/// What one pause sweep established: targets that were verifiably playing and
/// are now paused, and running browsers that refused tab scripting (their
/// "Allow JavaScript from Apple Events" preference is off).
struct MediaPauseScan: Equatable, Sendable {
	var paused: [MediaTarget] = []
	var blocked: [MediaTarget] = []
	/// What the player was playing when we paused it, so resume can refuse to
	/// start something the user swapped in mid-dictation. Browsers tag the
	/// elements they paused instead, so their scripts omit this segment.
	var identity: String?

	/// A player pause script returns `"<paused>|<blocked>|<track identity>"`; a
	/// browser one returns just `"<paused>|<blocked>"`.
	static func parse(_ output: String?) -> MediaPauseScan {
		guard let output else { return MediaPauseScan() }
		let segments = output.split(separator: "|", omittingEmptySubsequences: false)
		func targets(at index: Int) -> [MediaTarget] {
			guard segments.indices.contains(index) else { return [] }
			let tokens = Set(segments[index].split(whereSeparator: \.isWhitespace).map(String.init))
			return MediaTarget.allCases.filter { tokens.contains($0.token) }
		}
		let identity =
			segments.indices.contains(2)
			? segments[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
		return MediaPauseScan(
			paused: targets(at: 0), blocked: targets(at: 1),
			identity: identity.isEmpty ? nil : identity)
	}
}

/// One dictation's worth of paused media, and the rules for putting it back.
struct MediaPauseSession: Equatable, Sendable {
	let targets: [MediaTarget]
	let startedAt: Date
	/// Per-player proof of what was paused. A target missing from here is never
	/// resumed: we cannot show that what is loaded now is what we stopped.
	let identities: [MediaTarget: String]

	init(
		targets: [MediaTarget], startedAt: Date, identities: [MediaTarget: String] = [:]
	) {
		self.targets = targets
		self.startedAt = startedAt
		self.identities = identities
	}

	/// Past this gap the user has moved on — silently restarting their music
	/// would be a surprise, not a courtesy.
	static let maxResumeGap: TimeInterval = 600

	/// A blocked browser is not a session: nothing was paused, so there is
	/// nothing to resume and nothing worth remembering.
	static func started(
		from scan: MediaPauseScan, at date: Date, identities: [MediaTarget: String] = [:]
	) -> MediaPauseSession? {
		scan.paused.isEmpty
			? nil
			: MediaPauseSession(targets: scan.paused, startedAt: date, identities: identities)
	}

	func shouldResume(at date: Date) -> Bool {
		date.timeIntervalSince(startedAt) <= Self.maxResumeGap
	}
}

/// Pauses whatever the user is listening to for the duration of a dictation and
/// puts it back afterwards.
///
/// Everything is state-checked before it is touched: Music/Spotify through
/// `player state` plus the identity of the track we paused, browser tabs
/// through in-page JavaScript that pauses only elements that are actually
/// playing and tags them so resume can find exactly those elements again.
/// Whatever is left over — a browser that refused that JavaScript or never
/// answered at all, and every app we have no dictionary for — is muted instead
/// (`BrowserAudioMuter`), so a dictation is quiet whatever is playing. No blind
/// system media key, ever: a toggle sent without established playback can just
/// as easily start something, while a mute can only ever take sound away.
///
/// Every Apple Event runs out of process; the recording path only ever enqueues
/// work and returns. See WHI-W2.
@MainActor
final class MediaPlaybackCoordinator {
	static let shared = MediaPlaybackCoordinator()

	/// Keys of the `.browserMediaPauseBlocked` userInfo payload. Plain String and
	/// [String] values only — the payload crosses NotificationCenter.
	nonisolated static let blockedMessageKey = "recoveryMessage"
	nonisolated static let blockedBrowsersKey = "blockedBrowsers"

	private var session: MediaPauseSession?
	/// One recovery notification per browser per app run: the permission is a
	/// manual, persistent setting, so repeating the nudge every dictation would
	/// be noise.
	private var notifiedBlockedTargets: Set<MediaTarget> = []
	/// Serializes pause/resume so a resume can never overtake its own pause.
	private var work: Task<Void, Never>?

	private let playersEnabled: @Sendable () -> Bool
	private let browsersEnabled: @Sendable () -> Bool
	private let runScript: @Sendable (String) -> String?
	private let muteBlocked: @Sendable ([MediaTarget]) -> ([MediaTarget], [MediaTarget])
	private let muteRemaining: @Sendable (Bool) -> ([String], [String])
	private let unmuteAll: @Sendable () -> Void
	private let now: @Sendable () -> Date

	init(
		playersEnabled: @escaping @Sendable () -> Bool = { WhisperaSettings.pauseMediaWhileDictating },
		browsersEnabled: @escaping @Sendable () -> Bool = {
			WhisperaSettings.pauseMediaWhileDictating && WhisperaSettings.pauseBrowserMediaWhileDictating
		},
		// A closure literal rather than a bare function reference: an unapplied
		// declaration reference isn't inferred `@Sendable`.
		runScript: @escaping @Sendable (String) -> String? = { MediaPlaybackCoordinator.runOsascript($0) },
		muteBlocked: @escaping @Sendable ([MediaTarget]) -> ([MediaTarget], [MediaTarget]) = { targets in
			let outcome = BrowserAudioMuter.shared.muteAudiblyPlaying(targets)
			return (outcome.muted, outcome.audibleButUnmutable)
		},
		muteRemaining: @escaping @Sendable (Bool) -> ([String], [String]) = { excludingBrowsers in
			let outcome = BrowserAudioMuter.shared.muteRemainingAudibleProcesses(
				excludingBrowsers: excludingBrowsers)
			return (outcome.muted, outcome.unmutable)
		},
		unmuteAll: @escaping @Sendable () -> Void = { BrowserAudioMuter.shared.unmuteAll() },
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.playersEnabled = playersEnabled
		self.browsersEnabled = browsersEnabled
		self.runScript = runScript
		self.muteBlocked = muteBlocked
		self.muteRemaining = muteRemaining
		self.unmuteAll = unmuteAll
		self.now = now
	}

	// MARK: - Hooks

	/// Fire-and-forget: returns immediately, scripts run off the main actor.
	func pauseForDictation() {
		guard playersEnabled() || browsersEnabled() else { return }
		enqueue { await self.performPause() }
	}

	/// Recording-start hook. Unlike the fire-and-forget compatibility hook above,
	/// this does not return until the bounded pause sweep has finished, so media
	/// cannot leak into the beginning (or all) of a short dictation.
	func pauseBeforeDictation() async {
		guard playersEnabled() || browsersEnabled() else { return }
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
		enqueue { await self.performResume() }
	}

	/// Awaits all queued pause/resume work; exists for tests.
	func flush() async {
		await work?.value
	}

	private func enqueue(_ operation: @escaping @Sendable @MainActor () async -> Void) {
		let previous = work
		work = Task { @MainActor in
			await previous?.value
			await operation()
		}
	}

	// MARK: - Pause / resume

	// Pure function of its arguments; nonisolated so synchronous test code and
	// off-main callers don't need a main-actor hop for what is just a filter.
	nonisolated static func sweepTargets(players: Bool, browsers: Bool) -> [MediaTarget] {
		MediaTarget.allCases.filter { $0.isBrowser ? browsers : players }
	}

	private func performPause() async {
		session = nil
		let targets = Self.sweepTargets(players: playersEnabled(), browsers: browsersEnabled())
		guard !targets.isEmpty else { return }

		var scan = MediaPauseScan()
		var identities: [MediaTarget: String] = [:]
		// A browser whose script produced nothing at all — Automation denied, a
		// dictionary that would not load, a subprocess that died — is not
		// "nothing playing"; it is a browser whose state we never learned.
		var unresolved: [MediaTarget] = []
		// Every target is independent. Running the scripts concurrently bounds the
		// whole preflight to one transport deadline instead of six consecutive ones.
		let results = await withTaskGroup(of: (MediaTarget, String?).self) { group in
			for target in targets {
				group.addTask { [runScript] in
					(target, runScript(Self.pauseScript(for: target)))
				}
			}
			var collected: [(MediaTarget, String?)] = []
			for await result in group { collected.append(result) }
			return collected
		}
		for (target, output) in results {
			if output == nil, target.isBrowser { unresolved.append(target) }
			// Each script may only report about its own target; anything else in
			// the output is discarded.
			let sub = MediaPauseScan.parse(output)
			if sub.paused.contains(target) {
				scan.paused.append(target)
				if !target.isBrowser, let identity = sub.identity { identities[target] = identity }
			}
			if sub.blocked.contains(target) { scan.blocked.append(target) }
		}

		// A browser we could not pause gets muted instead. Without in-page
		// JavaScript there is no way to pause a tab, and every blind playback
		// playback command (media key, play) can just as easily START something
		// the user never began — but a CoreAudio mute tap can only take sound
		// away, so it is safe even on a browser whose state we never read. Only
		// one we proved is audible and still could not silence is worth
		// interrupting the user for.
		let mutable = scan.blocked + unresolved.filter { !scan.blocked.contains($0) }
		let (muted, unmutable) = await detachedMute(mutable)
		if !muted.isEmpty {
			AppLogger.shared.audioManager.info(
				"Muted browsers we could not pause: \(muted.map(\.rawValue).joined(separator: ", "))")
		}
		if !unmutable.isEmpty {
			AppLogger.shared.audioManager.info(
				"Browsers still audible after the mute attempt: \(unmutable.map(\.rawValue).joined(separator: ", "))")
			announceNewlyBlocked(unmutable)
		}

		// Everything else that is still making sound gets the same one-way mute.
		// This covers unlisted browsers and players without ever issuing a blind
		// playback toggle that could start an idle application.
		//
		// This pass still runs when browser handling is opted out: bundle ids let
		// it skip browsers while continuing to silence known players such as VLC,
		// Podcasts, and IINA.
		if playersEnabled() || browsersEnabled() {
			let (genericMuted, genericUnmutable) = await detachedMuteRemaining(
				excludingBrowsers: !browsersEnabled())
			if !genericMuted.isEmpty {
				AppLogger.shared.audioManager.info(
					"Muted other audible apps: \(genericMuted.joined(separator: ", "))")
			}
			if !genericUnmutable.isEmpty {
				// Logged, never announced: there is no setting the user could change
				// for an app we can only name by bundle id.
				AppLogger.shared.audioManager.info(
					"Could not mute audible apps: \(genericUnmutable.joined(separator: ", "))")
			}
		}

		session = MediaPauseSession.started(from: scan, at: now(), identities: identities)
		if let session {
			AppLogger.shared.audioManager.info(
				"Paused media for dictation: \(session.targets.map(\.rawValue).joined(separator: ", "))")
		}
	}

	// Posted with `object: self` so observers can scope to one coordinator.
	private func announceNewlyBlocked(_ blocked: [MediaTarget]) {
		let fresh = blocked.filter { !notifiedBlockedTargets.contains($0) }
		guard !fresh.isEmpty else { return }
		notifiedBlockedTargets.formUnion(fresh)

		let userInfo: [AnyHashable: Any] = [
			Self.blockedMessageKey: Self.blockedRecoveryMessage(for: fresh),
			Self.blockedBrowsersKey: fresh.map(\.rawValue),
		]
		NotificationCenter.default.post(
			name: .browserMediaPauseBlocked, object: self, userInfo: userInfo)
	}

	/// Names the browsers we could not pause and every permission that can be the
	/// reason: the browser's own JavaScript-from-Apple-Events switch, or macOS
	/// Automation access, which fails the script outright.
	nonisolated static func blockedRecoveryMessage(for targets: [MediaTarget]) -> String {
		guard !targets.isEmpty else { return "" }
		let names = targets.map(\.rawValue).joined(separator: ", ")
		let opening = "Whispera could not pause media in \(names) because it was refused the permissions it needs."

		var steps: [String] = []
		if targets.contains(.safari) {
			steps.append(
				"in Safari turn on the Develop menu in Settings > Advanced, then enable Develop > Allow JavaScript from Apple Events")
		}
		let chromium = targets.filter { $0.isBrowser && $0 != .safari }
		if !chromium.isEmpty {
			steps.append(
				"in \(chromium.map(\.rawValue).joined(separator: ", ")) enable View > Developer > Allow JavaScript from Apple Events")
		}
		steps.append(
			"and allow Whispera to control them under System Settings > Privacy & Security > Automation")
		return opening + " To fix it, " + steps.joined(separator: "; ") + "."
	}

	private func performResume() async {
		// Unconditionally first: a mute can exist without a session (a blocked
		// browser was the only thing playing), it outlives the resume window
		// because leaving the user silenced is never acceptable, and lifting it
		// can only reveal silence — never start playback.
		await detachedUnmute()

		guard let session else { return }
		self.session = nil

		guard session.shouldResume(at: now()) else {
			AppLogger.shared.audioManager.info("Skipping media resume — dictation outran the resume window")
			return
		}

		// Player scripts re-read `player state` and the track we captured, and
		// browser scripts only touch elements tagged during the pause, so
		// anything the user changed mid-dictation keeps their own choice.
		var resumed: [MediaTarget] = []
		for target in session.targets {
			if target.isBrowser {
				_ = await detached(Self.resumeScript(for: target, identity: ""))
			} else {
				guard let identity = session.identities[target] else {
					AppLogger.shared.audioManager.info(
						"Declining \(target.rawValue) resume — the paused track was never identified")
					continue
				}
				_ = await detached(Self.resumeScript(for: target, identity: identity))
			}
			resumed.append(target)
		}
		guard !resumed.isEmpty else { return }
		AppLogger.shared.audioManager.info(
			"Resumed media after dictation: \(resumed.map(\.rawValue).joined(separator: ", "))")
	}

	private func detached(_ source: String) async -> String? {
		let run = runScript
		return await Task.detached { run(source) }.value
	}

	/// CoreAudio property reads and tap creation are synchronous IPC to
	/// coreaudiod, so they go off the main actor exactly like the scripts do.
	private func detachedMute(_ targets: [MediaTarget]) async -> ([MediaTarget], [MediaTarget]) {
		let mute = muteBlocked
		return await Task.detached { mute(targets) }.value
	}

	private func detachedMuteRemaining(excludingBrowsers: Bool) async -> ([String], [String]) {
		let mute = muteRemaining
		return await Task.detached { mute(excludingBrowsers) }.value
	}

	private func detachedUnmute() async {
		let unmute = unmuteAll
		await Task.detached { unmute() }.value
	}

	// MARK: - Scripts

	// The whole script section is nonisolated: every member is a pure string
	// builder over immutable data, and the class's @MainActor isolation would
	// otherwise force a hop just to assemble AppleScript source.

	/// In-page JS for the pause sweep: pause only elements that are actually
	/// playing and tag them so the resume sweep can find exactly these elements.
	/// Single-quoted throughout so it embeds in an AppleScript string literal.
	nonisolated static let pauseTabScript =
		"(function(){var n=0;var l=document.querySelectorAll('video,audio');"
		+ "for(var i=0;i<l.length;i++){var m=l[i];"
		+ "if(!m.paused&&!m.ended){m.pause();m.dataset.whisperaPaused='1';n++;}}"
		+ "return n;})();"

	/// In-page JS for the resume sweep: replay only tagged elements that are
	/// still paused, and clear the tag either way.
	nonisolated static let resumeTabScript =
		"(function(){var n=0;"
		+ "var l=document.querySelectorAll('video[data-whispera-paused],audio[data-whispera-paused]');"
		+ "for(var i=0;i<l.length;i++){var m=l[i];delete m.dataset.whisperaPaused;"
		+ "if(m.paused){m.play();n++;}}"
		+ "return n;})();"

	/// One script per target, because AppleScript resolves app terminology at
	/// compile time: a machine without, say, Brave would fail the compile for
	/// everything sharing its script, and only loses Brave's sweep this way.
	/// Guarded by `is running` so a stopped app is never launched just to be
	/// asked whether it is playing. Players return
	/// `"<paused tokens>|<blocked tokens>|<track identity>"`, browsers
	/// `"<paused tokens>|<blocked tokens>"`.
	nonisolated static func pauseScript(for target: MediaTarget) -> String {
		guard !target.isBrowser else {
			return """
				set pausedList to ""
				set blockedList to ""
				\(browserPauseFragment(target))
				return pausedList & "|" & blockedList
				"""
		}
		return """
			set pausedList to ""
			set blockedList to ""
			set trackIdentity to ""
			\(playerPauseFragment(target))
			return pausedList & "|" & blockedList & "|" & trackIdentity
			"""
	}

	/// `identity` is the track the pause sweep captured; browsers ignore it,
	/// because their resume is already scoped to the elements it tagged.
	nonisolated static func resumeScript(for target: MediaTarget, identity: String) -> String {
		target.isBrowser ? browserResumeFragment(target) : playerResumeFragment(target, identity)
	}

	/// The identity read is wrapped so a player with no current track still
	/// pauses — it just becomes one we will not resume.
	private nonisolated static func playerPauseFragment(_ target: MediaTarget) -> String {
		"""
		if application "\(target.rawValue)" is running then
			tell application "\(target.rawValue)"
				if player state is playing then
					try
						set trackIdentity to \(trackIdentityExpression(target))
					end try
					pause
					set pausedList to pausedList & "\(target.token) "
				end if
			end tell
		end if
		"""
	}

	/// A tab whose `try` fails (JavaScript from Apple Events turned off, or a
	/// page that rejects injection) is reported as blocked and left untouched —
	/// the failure never escalates into a blind fallback.
	private nonisolated static func browserPauseFragment(_ target: MediaTarget) -> String {
		"""
		if application "\(target.rawValue)" is running then
			tell application "\(target.rawValue)"
				set tabCount to 0
				repeat with w in windows
					repeat with t in tabs of w
						try
							set tabCount to tabCount + (\(tabJS(target, Self.pauseTabScript)))
						on error
							set blockedList to blockedList & "\(target.token) "
						end try
					end repeat
				end repeat
				if tabCount > 0 then set pausedList to pausedList & "\(target.token) "
			end tell
		end if
		"""
	}

	/// Only `paused` resumes: a stopped player is either one the user deliberately
	/// stopped mid-dictation or a fresh launch, and `is not playing` would start
	/// both of them. The identity check adds the other half: a user who queued a
	/// different track mid-dictation gets left alone, because playing it would be
	/// starting something we never stopped.
	private nonisolated static func playerResumeFragment(_ target: MediaTarget, _ identity: String)
		-> String
	{
		"""
		if application "\(target.rawValue)" is running then
			tell application "\(target.rawValue)"
				if player state is paused then
					set currentIdentity to ""
					try
						set currentIdentity to \(trackIdentityExpression(target))
					end try
					if currentIdentity is \(quoted(identity)) then play
				end if
			end tell
		end if
		"""
	}

	/// Music identifies a track by its library-persistent ID, Spotify by its
	/// track URI; both are stable for as long as one item stays loaded.
	private nonisolated static func trackIdentityExpression(_ target: MediaTarget) -> String {
		target == .spotify
			? "((id of current track) as text)" : "((persistent ID of current track) as text)"
	}

	/// The identity round-trips through AppleScript source, so it has to survive
	/// being pasted into a string literal even though players only ever hand back
	/// hex IDs and URIs.
	private nonisolated static func quoted(_ value: String) -> String {
		let escaped =
			value
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		return "\"\(escaped)\""
	}

	private nonisolated static func browserResumeFragment(_ target: MediaTarget) -> String {
		"""
		if application "\(target.rawValue)" is running then
			tell application "\(target.rawValue)"
				repeat with w in windows
					repeat with t in tabs of w
						try
							\(tabJS(target, Self.resumeTabScript))
						end try
					end repeat
				end repeat
			end tell
		end if
		"""
	}

	/// Safari and the Chromium family expose the same capability under
	/// different AppleScript commands.
	private nonisolated static func tabJS(_ target: MediaTarget, _ js: String) -> String {
		target == .safari ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
	}

	// MARK: - Transport

	/// Runs AppleScript out of process with a hard deadline. A wedged browser or
	/// first-run TCC interaction must not hold the serial pause queue forever and
	/// thereby prevent the safe CoreAudio fallback or the eventual unmute.
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

		let deadline = Date().addingTimeInterval(2)
		while process.isRunning && Date() < deadline {
			Thread.sleep(forTimeInterval: 0.01)
		}
		if process.isRunning {
			process.terminate()
			// terminate() is asynchronous. Bound this grace period too; closing the
			// read handle below makes the call return even if the child ignores TERM.
			let terminationDeadline = Date().addingTimeInterval(0.25)
			while process.isRunning && Date() < terminationDeadline {
				Thread.sleep(forTimeInterval: 0.01)
			}
			pipe.fileHandleForReading.closeFile()
			return nil
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		guard process.terminationStatus == 0 else { return nil }
		return String(data: data, encoding: .utf8)
	}
}
