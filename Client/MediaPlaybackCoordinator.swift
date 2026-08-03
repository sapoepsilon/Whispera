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

	/// A pause script returns `"<paused tokens>|<blocked tokens>"`.
	static func parse(_ output: String?) -> MediaPauseScan {
		guard let output else { return MediaPauseScan() }
		let segments = output.split(separator: "|", omittingEmptySubsequences: false)
		func targets(at index: Int) -> [MediaTarget] {
			guard segments.indices.contains(index) else { return [] }
			let tokens = Set(segments[index].split(whereSeparator: \.isWhitespace).map(String.init))
			return MediaTarget.allCases.filter { tokens.contains($0.token) }
		}
		return MediaPauseScan(paused: targets(at: 0), blocked: targets(at: 1))
	}
}

/// One dictation's worth of paused media, and the rules for putting it back.
struct MediaPauseSession: Equatable, Sendable {
	let targets: [MediaTarget]
	let startedAt: Date

	/// Past this gap the user has moved on — silently restarting their music
	/// would be a surprise, not a courtesy.
	static let maxResumeGap: TimeInterval = 600

	/// A blocked browser is not a session: nothing was paused, so there is
	/// nothing to resume and nothing worth remembering.
	static func started(from scan: MediaPauseScan, at date: Date) -> MediaPauseSession? {
		scan.paused.isEmpty ? nil : MediaPauseSession(targets: scan.paused, startedAt: date)
	}

	func shouldResume(at date: Date) -> Bool {
		date.timeIntervalSince(startedAt) <= Self.maxResumeGap
	}
}

/// Pauses whatever the user is listening to for the duration of a dictation and
/// puts it back afterwards.
///
/// Everything is state-checked before it is touched: Music/Spotify through
/// `player state`, browser tabs through in-page JavaScript that pauses only
/// elements that are actually playing and tags them so resume can find exactly
/// those elements again. No blind system media key, ever — a toggle sent
/// without established playback can just as easily start something.
///
/// Every Apple Event runs out of process; the recording path only ever enqueues
/// work and returns. See WHI-W2.
@MainActor
final class MediaPlaybackCoordinator {
	static let shared = MediaPlaybackCoordinator()

	private var session: MediaPauseSession?
	/// Serializes pause/resume so a resume can never overtake its own pause.
	private var work: Task<Void, Never>?

	private let playersEnabled: @Sendable () -> Bool
	private let browsersEnabled: @Sendable () -> Bool
	private let runScript: @Sendable (String) -> String?
	private let now: @Sendable () -> Date

	init(
		playersEnabled: @escaping @Sendable () -> Bool = { WhisperaSettings.pauseMediaWhileDictating },
		browsersEnabled: @escaping @Sendable () -> Bool = {
			WhisperaSettings.pauseMediaWhileDictating && WhisperaSettings.pauseBrowserMediaWhileDictating
		},
		// A closure literal rather than a bare function reference: an unapplied
		// declaration reference isn't inferred `@Sendable`.
		runScript: @escaping @Sendable (String) -> String? = { MediaPlaybackCoordinator.runOsascript($0) },
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.playersEnabled = playersEnabled
		self.browsersEnabled = browsersEnabled
		self.runScript = runScript
		self.now = now
	}

	// MARK: - Hooks

	/// Fire-and-forget: returns immediately, scripts run off the main actor.
	func pauseForDictation() {
		guard playersEnabled() || browsersEnabled() else { return }
		enqueue { await self.performPause() }
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
		for target in targets {
			// Each script may only report about its own target; anything else in
			// the output is discarded.
			let sub = MediaPauseScan.parse(await detached(Self.pauseScript(for: target)))
			if sub.paused.contains(target) { scan.paused.append(target) }
			if sub.blocked.contains(target) { scan.blocked.append(target) }
		}

		if !scan.blocked.isEmpty {
			AppLogger.shared.audioManager.info(
				"Browsers refused tab scripting — enable \"Allow JavaScript from Apple Events\": \(scan.blocked.map(\.rawValue).joined(separator: ", "))")
		}

		session = MediaPauseSession.started(from: scan, at: now())
		if let session {
			AppLogger.shared.audioManager.info(
				"Paused media for dictation: \(session.targets.map(\.rawValue).joined(separator: ", "))")
		}
	}

	private func performResume() async {
		guard let session else { return }
		self.session = nil

		guard session.shouldResume(at: now()) else {
			AppLogger.shared.audioManager.info("Skipping media resume — dictation outran the resume window")
			return
		}

		// Player scripts re-read `player state` and browser scripts only touch
		// elements tagged during the pause, so anything the user restarted
		// themselves mid-dictation keeps their own choice.
		for target in session.targets {
			_ = await detached(Self.resumeScript(for: target))
		}
		AppLogger.shared.audioManager.info(
			"Resumed media after dictation: \(session.targets.map(\.rawValue).joined(separator: ", "))")
	}

	private func detached(_ source: String) async -> String? {
		let run = runScript
		return await Task.detached { run(source) }.value
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
	/// asked whether it is playing. Returns `"<paused tokens>|<blocked tokens>"`.
	nonisolated static func pauseScript(for target: MediaTarget) -> String {
		"""
		set pausedList to ""
		set blockedList to ""
		\(target.isBrowser ? browserPauseFragment(target) : playerPauseFragment(target))
		return pausedList & "|" & blockedList
		"""
	}

	nonisolated static func resumeScript(for target: MediaTarget) -> String {
		target.isBrowser ? browserResumeFragment(target) : playerResumeFragment(target)
	}

	private nonisolated static func playerPauseFragment(_ target: MediaTarget) -> String {
		"""
		if application "\(target.rawValue)" is running then
			tell application "\(target.rawValue)"
				if player state is playing then
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

	private nonisolated static func playerResumeFragment(_ target: MediaTarget) -> String {
		"""
		if application "\(target.rawValue)" is running then
			tell application "\(target.rawValue)"
				if player state is not playing then play
			end tell
		end if
		"""
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
}
