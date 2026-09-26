import Foundation

struct CLIOptions: Equatable {
	enum Action: Equatable {
		case help
		case listModels
		case listDevices
		case transcribe
		case remote(RemoteCommand)
	}

	var action: Action = .help
	var files: [String] = []
	var model: String?
	var deviceIndex: Int?
	var language: String?
	var translate = false
	var repeatCount = 1
	var json = false
	var debug = false

	enum ParseError: Error, Equatable, LocalizedError {
		case missingValue(String)
		case invalidNumber(String, String)
		case unknownArgument(String)
		case conflictingActions
		case optionNeedsFile(String)

		var errorDescription: String? {
			switch self {
			case .missingValue(let flag): return "\(flag) needs a value"
			case .invalidNumber(let flag, let value): return "\(flag) expects a positive number, got '\(value)'"
			case .unknownArgument(let argument): return "Unknown argument: \(argument)"
			case .conflictingActions: return "Pick one of --transcribe-file, --list-models, --list-devices or a remote command"
			case .optionNeedsFile(let flag): return "\(flag) only applies with --transcribe-file"
			}
		}
	}

	/// Flags that switch the app binary into headless mode. Anything else (including the
	/// -NSDocumentRevisionsDebugMode style arguments Xcode and XCTest pass) launches the GUI.
	static let triggerFlags: Set<String> = [
		"-f", "--transcribe-file", "--list-models", "--list-devices", "--toggle-transcription", "--toggle",
		"--start", "--stop", "--cancel", "--help", "-h",
	]

	static func isCLIInvocation(_ arguments: [String]) -> Bool {
		arguments.contains { argument in
			let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
			return triggerFlags.contains(flag)
		}
	}

	static func parse(_ arguments: [String]) throws -> CLIOptions {
		var options = CLIOptions()
		var actions: [Action] = []
		var index = 0

		func nextValue(for flag: String, inline: String?) throws -> String {
			if let inline {
				guard !inline.isEmpty else { throw ParseError.missingValue(flag) }
				return inline
			}
			index += 1
			guard index < arguments.count, !arguments[index].hasPrefix("--") else {
				throw ParseError.missingValue(flag)
			}
			return arguments[index]
		}

		func positiveInt(_ flag: String, _ value: String, allowZero: Bool) throws -> Int {
			guard let number = Int(value), number > 0 || (allowZero && number == 0) else {
				throw ParseError.invalidNumber(flag, value)
			}
			return number
		}

		while index < arguments.count {
			let argument = arguments[index]
			let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
			let flag = argument.hasPrefix("--") ? parts[0] : argument
			let inline = argument.hasPrefix("--") && parts.count == 2 ? parts[1] : nil

			switch flag {
			case "-h", "--help":
				actions.append(.help)
			case "-f", "--transcribe-file":
				options.files.append(try nextValue(for: flag, inline: inline))
				if !actions.contains(.transcribe) { actions.append(.transcribe) }
			case "--list-models":
				actions.append(.listModels)
			case "--list-devices":
				actions.append(.listDevices)
			case "--toggle", "--toggle-transcription":
				actions.append(.remote(.toggle))
			case "--start":
				actions.append(.remote(.start))
			case "--stop":
				actions.append(.remote(.stop))
			case "--cancel":
				actions.append(.remote(.cancel))
			case "--model":
				options.model = try nextValue(for: flag, inline: inline)
			case "--device-index":
				let value = try nextValue(for: flag, inline: inline)
				options.deviceIndex = try positiveInt(flag, value, allowZero: true)
			case "--language":
				options.language = try nextValue(for: flag, inline: inline)
			case "--translate":
				options.translate = true
			case "--repeat":
				options.repeatCount = try positiveInt(flag, try nextValue(for: flag, inline: inline), allowZero: false)
			case "--json":
				options.json = true
			case "--debug":
				options.debug = true
			default:
				// macOS may append -psn_ or -NS* pairs when launching bundles; skip them.
				if argument.hasPrefix("-psn_") {
					break
				} else if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
					index += 1
				} else {
					throw ParseError.unknownArgument(argument)
				}
			}
			index += 1
		}

		if actions.contains(.help) {
			options.action = .help
			return options
		}
		guard actions.count <= 1 else { throw ParseError.conflictingActions }
		options.action = actions.first ?? .help

		if options.action != .transcribe {
			if options.model != nil { throw ParseError.optionNeedsFile("--model") }
			if options.deviceIndex != nil { throw ParseError.optionNeedsFile("--device-index") }
			if options.repeatCount != 1 { throw ParseError.optionNeedsFile("--repeat") }
			if options.language != nil { throw ParseError.optionNeedsFile("--language") }
			if options.translate { throw ParseError.optionNeedsFile("--translate") }
		}
		return options
	}

	static let usage = """
		Usage: Whispera [options]

		Headless transcription (the model must already be downloaded in the app):
		  -f, --transcribe-file <path>  Transcribe an audio file and exit (repeatable)
		  --model <id>                  Model to load (default: the model selected in the app)
		  --device-index <n>            Compute device from --list-devices (default 0)
		  --language <name|code|auto>   Spoken language (default: the app setting)
		  --translate                   Translate to English
		  --repeat <n>                  Transcribe each file n times; best_ms is the fastest run
		  --json                        Print machine-readable JSON
		  --debug                       Verbose WhisperKit logging on stderr

		  --list-models                 List downloaded models and exit (honors --json)
		  --list-devices                List compute devices and exit (honors --json)

		Control the running app (sent through whispera:// links):
		  --toggle, --toggle-transcription   Start or stop dictation
		  --start | --stop | --cancel        Start, stop, or discard the recording

		  -h, --help                    Show this help
		"""
}
