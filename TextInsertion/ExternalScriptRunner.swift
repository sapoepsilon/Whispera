import Darwin
import Foundation

enum ExternalScriptError: LocalizedError, Equatable {
	case notConfigured
	case notExecutable(String)
	case notApproved
	case unsafePermissions(String)
	case launchFailed(String)
	case timedOut
	case failed(exitCode: Int32)

	var errorDescription: String? {
		switch self {
		case .notConfigured: return "No insertion script is configured"
		case .notExecutable(let path): return "\(path) is not an executable file"
		case .notApproved:
			return "The insertion script changed or was not chosen in Settings. Choose it again to allow it."
		case .unsafePermissions(let reason): return "The insertion script is not safe to run: \(reason)"
		case .launchFailed(let reason): return "The insertion script could not start: \(reason)"
		case .timedOut: return "The insertion script did not finish in time"
		case .failed(let code): return "The insertion script exited with code \(code)"
		}
	}
}

/// Runs the user's insertion script. Whispera's microphone and Accessibility grants are
/// attributed to its children, so the script must be one the user picked in Settings, unchanged
/// since, and not writable by anyone else.
enum ExternalScriptRunner {
	static let transcriptEnvironmentKey = "WHISPERA_TRANSCRIPT"
	static let scriptPathEnvironmentKey = "WHISPERA_SCRIPT_PATH"
	/// The folder the chosen script lives in. `$0` is the private copy that actually runs, so
	/// scripts that used `$(dirname "$0")` to find files next to them use this instead.
	static let scriptDirectoryEnvironmentKey = "WHISPERA_SCRIPT_DIR"
	static let defaultTimeout: TimeInterval = 10
	/// Time between SIGTERM and SIGKILL for a script that overruns its timeout.
	static let terminationGrace: TimeInterval = 1

	/// Resolves symlinks so the file that was checked is the file that runs.
	static func validate(path: String) throws -> URL {
		let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw ExternalScriptError.notConfigured }
		let expanded = (trimmed as NSString).expandingTildeInPath
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
			!isDirectory.boolValue,
			FileManager.default.isExecutableFile(atPath: expanded),
			let resolved = realpath(expanded, nil)
		else { throw ExternalScriptError.notExecutable(expanded) }
		defer { free(resolved) }
		return URL(fileURLWithPath: String(cString: resolved))
	}

	/// The script and its folder must belong to this user (or root) and must not be writable by
	/// other users, or someone else could swap in their own code between runs.
	static func checkOwnershipAndPermissions(of path: String) throws {
		let uid = getuid()
		var file = stat()
		guard stat(path, &file) == 0 else { throw ExternalScriptError.notExecutable(path) }
		guard file.st_uid == uid || file.st_uid == 0 else {
			throw ExternalScriptError.unsafePermissions("it is owned by another user")
		}
		guard file.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
			throw ExternalScriptError.unsafePermissions("it is writable by other users")
		}
		let folder = (path as NSString).deletingLastPathComponent
		var directory = stat()
		guard stat(folder, &directory) == 0 else { throw ExternalScriptError.notExecutable(path) }
		let sharedWritable = directory.st_mode & (S_IWGRP | S_IWOTH) != 0
		let sticky = directory.st_mode & S_ISVTX != 0
		guard directory.st_uid == uid || directory.st_uid == 0, !sharedWritable || sticky else {
			throw ExternalScriptError.unsafePermissions("its folder is writable by other users")
		}
	}

	/// Only what a script needs to find tools and a home; nothing of Whispera's own environment.
	static func minimalEnvironment(
		transcript: String, scriptPath: String? = nil,
		from parent: [String: String] = ProcessInfo.processInfo.environment
	) -> [String: String] {
		var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"]
		for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
			if let value = parent[key] { environment[key] = value }
		}
		environment[transcriptEnvironmentKey] = transcript
		if let scriptPath {
			environment[scriptPathEnvironmentKey] = scriptPath
			environment[scriptDirectoryEnvironmentKey] = (scriptPath as NSString).deletingLastPathComponent
		}
		return environment
	}

	/// The transcript goes to the script on standard input and in WHISPERA_TRANSCRIPT, never in
	/// argv, which any local user can read with `ps`. `onApprovalUpgraded` receives the new value
	/// to store when the approval was signed in an older format.
	static func run(
		path: String, approval: String, text: String, timeout: TimeInterval = defaultTimeout,
		keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore(),
		onApprovalUpgraded: (String) -> Void = { _ in }
	) async throws {
		let url = try validate(path: path)
		try checkOwnershipAndPermissions(of: url.path)
		let snapshot = try ScriptFingerprint.snapshot(path: url.path)
		let verdict = ScriptApproval.verdict(snapshot: snapshot, approval: approval, keyStore: keyStore)
		guard verdict.isApproved else { throw ExternalScriptError.notApproved }
		if let upgraded = verdict.upgradedApproval { onApprovalUpgraded(upgraded) }
		try await execute(snapshot: snapshot, text: text, timeout: timeout)
	}

	/// Runs a private copy of the verified bytes, so replacing the script between the approval
	/// check and the launch cannot change what runs. The script starts in its own folder and finds
	/// its real path in WHISPERA_SCRIPT_PATH and its folder in WHISPERA_SCRIPT_DIR; `$0` is the copy.
	static func execute(
		snapshot: ScriptFingerprint.Snapshot, text: String, timeout: TimeInterval = defaultTimeout
	) async throws {
		let original = snapshot.fingerprint.path
		let copy = try VerifiedScriptCopy.make(contents: snapshot.contents, name: (original as NSString).lastPathComponent)
		let child: SpawnedScript
		do {
			child = try SpawnedScript.launch(
				executable: copy.executable,
				workingDirectory: (original as NSString).deletingLastPathComponent,
				environment: minimalEnvironment(transcript: text, scriptPath: original),
				input: Data(text.utf8))
		} catch {
			copy.remove()
			throw error
		}

		let status: Int32? = await withCheckedContinuation { continuation in
			let resumed = ResumeOnce()
			DispatchQueue.global(qos: .userInitiated).async {
				let status = child.waitForExit()
				copy.remove()
				if resumed.claim() { continuation.resume(returning: status) }
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
				guard resumed.claim() else { return }
				child.terminateGroup(grace: terminationGrace)
				continuation.resume(returning: nil)
			}
		}

		guard let status else { throw ExternalScriptError.timedOut }
		guard status == 0 else { throw ExternalScriptError.failed(exitCode: status) }
	}
}

/// A single-use copy of an approved script inside a folder only this user can open.
struct VerifiedScriptCopy: Sendable {
	static let folderName = "Whispera-scripts"

	let folder: URL
	let executable: String

	static func privateRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
		if mkdir(root.path, 0o700) != 0, errno != EEXIST {
			throw ExternalScriptError.launchFailed(String(cString: strerror(errno)))
		}
		var info = stat()
		guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
			throw ExternalScriptError.unsafePermissions("its run folder is not private")
		}
		if info.st_mode & 0o077 != 0, chmod(root.path, 0o700) != 0 {
			throw ExternalScriptError.unsafePermissions("its run folder is not private")
		}
		return root
	}

	static func make(contents: Data, name: String) throws -> VerifiedScriptCopy {
		let folder = try privateRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
		guard mkdir(folder.path, 0o700) == 0 else {
			throw ExternalScriptError.launchFailed(String(cString: strerror(errno)))
		}
		let copy = VerifiedScriptCopy(folder: folder, executable: folder.appendingPathComponent(name).path)
		let fd = open(copy.executable, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
		guard fd >= 0 else {
			let reason = String(cString: strerror(errno))
			copy.remove()
			throw ExternalScriptError.launchFailed(reason)
		}
		let written = contents.withUnsafeBytes { buffer -> Bool in
			var offset = 0
			while offset < buffer.count {
				let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
				if count < 0 {
					if errno == EINTR { continue }
					return false
				}
				offset += count
			}
			return true
		}
		let sealed = fchmod(fd, 0o500) == 0
		close(fd)
		guard written, sealed else {
			copy.remove()
			throw ExternalScriptError.launchFailed("could not copy the script")
		}
		return copy
	}

	func remove() {
		try? FileManager.default.removeItem(at: folder)
	}

	/// Removes copies left behind when Whispera quit or crashed while a script ran. Copies younger
	/// than `minimumAge` may belong to a script still running and are kept.
	@discardableResult
	static func removeLeftovers(
		in root: URL? = nil, minimumAge: TimeInterval = 10 * 60, now: Date = Date()
	) -> Int {
		let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
		var info = stat()
		// Never follow a planted symlink or clean a folder that is not ours
		guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
			let entries = try? FileManager.default.contentsOfDirectory(
				at: root, includingPropertiesForKeys: [.contentModificationDateKey])
		else { return 0 }
		var removed = 0
		for entry in entries {
			let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
			guard let modified = values?.contentModificationDate, now.timeIntervalSince(modified) >= minimumAge
			else { continue }
			if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
		}
		if removed > 0 {
			AppLogger.shared.general.info("Removed \(removed) leftover insertion script copies")
		}
		return removed
	}
}

/// A script started in its own process group, so a timeout can stop everything it spawned.
private struct SpawnedScript: Sendable {
	let pid: pid_t

	static func launch(
		executable: String, workingDirectory: String, environment: [String: String], input: Data
	) throws -> SpawnedScript {
		var pipeFDs: [Int32] = [0, 0]
		guard pipe(&pipeFDs) == 0 else {
			throw ExternalScriptError.launchFailed(String(cString: strerror(errno)))
		}
		let readFD = pipeFDs[0]
		let writeFD = pipeFDs[1]
		// A script that exits without reading stdin must not kill Whispera with SIGPIPE
		_ = fcntl(writeFD, F_SETNOSIGPIPE, 1)

		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_adddup2(&actions, readFD, STDIN_FILENO)
		posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
		posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
		posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }
		// CLOEXEC_DEFAULT keeps every other Whispera descriptor out of the script
		let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
			| POSIX_SPAWN_SETSIGMASK
		posix_spawnattr_setflags(&attributes, Int16(flags))
		posix_spawnattr_setpgroup(&attributes, 0)
		var defaultSignals = sigset_t()
		sigfillset(&defaultSignals)
		posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
		var noMask = sigset_t()
		sigemptyset(&noMask)
		posix_spawnattr_setsigmask(&attributes, &noMask)

		let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
		let envp: [UnsafeMutablePointer<CChar>?] =
			environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
		defer {
			argv.forEach { free($0) }
			envp.forEach { free($0) }
		}

		var pid: pid_t = 0
		let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
		close(readFD)
		guard result == 0 else {
			close(writeFD)
			throw ExternalScriptError.launchFailed(String(cString: strerror(result)))
		}

		// Written off the caller so a script that never reads a long transcript cannot block it
		DispatchQueue.global(qos: .userInitiated).async {
			input.withUnsafeBytes { buffer in
				var offset = 0
				while offset < buffer.count {
					let written = write(writeFD, buffer.baseAddress! + offset, buffer.count - offset)
					if written < 0 {
						if errno == EINTR { continue }
						break
					}
					offset += written
				}
			}
			close(writeFD)
		}
		return SpawnedScript(pid: pid)
	}

	/// Blocks until the script exits and returns its exit code (128 + signal when killed).
	func waitForExit() -> Int32 {
		var status: Int32 = 0
		while waitpid(pid, &status, 0) < 0 {
			guard errno == EINTR else { return -1 }
		}
		let signal = status & 0x7f
		return signal == 0 ? (status >> 8) & 0xff : 128 + signal
	}

	func terminateGroup(grace: TimeInterval) {
		kill(-pid, SIGTERM)
		DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
			kill(-pid, SIGKILL)
		}
	}
}

private final class ResumeOnce: @unchecked Sendable {
	private let lock = NSLock()
	private var claimed = false

	func claim() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !claimed else { return false }
		claimed = true
		return true
	}
}
