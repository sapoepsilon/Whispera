import Foundation

enum ExternalScriptError: LocalizedError, Equatable {
	case notConfigured
	case notExecutable(String)
	case launchFailed(String)
	case timedOut
	case failed(exitCode: Int32)

	var errorDescription: String? {
		switch self {
		case .notConfigured: return "No insertion script is configured"
		case .notExecutable(let path): return "\(path) is not an executable file"
		case .launchFailed(let reason): return "The insertion script could not start: \(reason)"
		case .timedOut: return "The insertion script did not finish in time"
		case .failed(let code): return "The insertion script exited with code \(code)"
		}
	}
}

enum ExternalScriptRunner {
	static let transcriptEnvironmentKey = "WHISPERA_TRANSCRIPT"
	static let defaultTimeout: TimeInterval = 10

	static func validate(path: String) throws -> URL {
		let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw ExternalScriptError.notConfigured }
		let expanded = (trimmed as NSString).expandingTildeInPath
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
			!isDirectory.boolValue,
			FileManager.default.isExecutableFile(atPath: expanded)
		else { throw ExternalScriptError.notExecutable(expanded) }
		return URL(fileURLWithPath: expanded)
	}

	// Output is discarded rather than piped so a script that forks a long-lived helper cannot stall us
	static func run(path: String, text: String, timeout: TimeInterval = defaultTimeout) async throws {
		let url = try validate(path: path)
		let process = Process()
		process.executableURL = url
		process.arguments = [text]
		var environment = ProcessInfo.processInfo.environment
		environment[transcriptEnvironmentKey] = text
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice

		let status: Int32? = try await withCheckedThrowingContinuation { continuation in
			let resumed = ResumeOnce()
			process.terminationHandler = { finished in
				if resumed.claim() { continuation.resume(returning: finished.terminationStatus) }
			}
			do {
				try process.run()
			} catch {
				if resumed.claim() {
					continuation.resume(
						throwing: ExternalScriptError.launchFailed(error.localizedDescription))
				}
				return
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
				guard resumed.claim() else { return }
				process.terminate()
				continuation.resume(returning: nil)
			}
		}

		guard let status else { throw ExternalScriptError.timedOut }
		guard status == 0 else { throw ExternalScriptError.failed(exitCode: status) }
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
