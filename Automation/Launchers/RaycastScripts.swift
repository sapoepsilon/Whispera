import Foundation

/// Raycast script commands that drive Whispera through its CLI and the whispera:// scheme.
/// The same text is committed under integrations/raycast so it can be installed without the app.
struct RaycastScriptCommand: Equatable {
	enum Mode: String {
		case silent
		case fullOutput
	}

	let fileName: String
	let title: String
	let description: String
	let mode: Mode
	let argumentPlaceholder: String?
	let body: String

	func render() -> String {
		var lines = [
			"#!/bin/bash",
			"",
			"# Required parameters:",
			"# @raycast.schemaVersion 1",
			"# @raycast.title \(title)",
			"# @raycast.mode \(mode.rawValue)",
			"",
			"# Optional parameters:",
			"# @raycast.packageName Whispera",
		]
		if let argumentPlaceholder {
			lines.append("# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"\(argumentPlaceholder)\" }")
		}
		lines += [
			"",
			"# Documentation:",
			"# @raycast.description \(description)",
			"# @raycast.author Whispera",
			"",
			body,
		]
		return lines.joined(separator: "\n") + "\n"
	}
}

enum RaycastScripts {
	static let defaultCLIPath = "/Applications/Whispera.app/Contents/MacOS/Whispera"
	static let defaultBundleIdentifier = "com.macwhisper.app"
	static let linksOffHint = "Turn on \"Allow whispera:// links\" in Whispera Settings > Automation, then try again."

	/// Read at run time so the token never lands in a committed or shared script.
	static let tokenLine =
		"token=\"$(cat \"$HOME/Library/Application Support/Whispera/\(RemoteControlToken.fileName)\" 2>/dev/null)\""

	/// Links are off by default and a rejected `open whispera://…` fails silently, so scripts that
	/// only have a link check the setting first and print what to turn on.
	static func linksEnabledCheck(bundleIdentifier: String) -> String {
		let domain = escapeForDoubleQuotes(bundleIdentifier)
		return """
			if [ "$(defaults read "\(domain)" \(RemoteControlSettings.urlSchemeEnabledKey) 2>/dev/null)" != "1" ]; then
			  echo "\(escapeForDoubleQuotes(linksOffHint))"
			  exit 1
			fi
			"""
	}

	static func commands(
		cliPath: String = defaultCLIPath, bundleIdentifier: String = defaultBundleIdentifier
	) -> [RaycastScriptCommand] {
		let cli = "WHISPERA=\"${WHISPERA_CLI:-\(escapeForDoubleQuotes(cliPath))}\""
		let linksCheck = linksEnabledCheck(bundleIdentifier: bundleIdentifier)
		// The CLI reads the token, targets its own app bundle and prints why a command was refused
		func cliCommand(_ flag: String, _ verb: String, title: String, description: String) -> RaycastScriptCommand {
			RaycastScriptCommand(
				fileName: "whispera-\(verb).sh", title: title, description: description, mode: .silent,
				argumentPlaceholder: nil,
				body: """
					\(cli)
					"$WHISPERA" \(flag) 2>&1
					""")
		}
		return [
			cliCommand("--toggle", "toggle", title: "Toggle Dictation", description: "Start or stop Whispera dictation."),
			cliCommand("--start", "start", title: "Start Dictation", description: "Start Whispera dictation."),
			cliCommand(
				"--stop", "stop", title: "Stop Dictation",
				description: "Stop Whispera dictation and paste the transcript."),
			cliCommand(
				"--cancel", "cancel", title: "Cancel Dictation",
				description: "Stop Whispera dictation and discard the recording."),
			cliCommand(
				"--copy-last", "copy-last", title: "Copy Last Transcript",
				description: "Copy the most recent Whispera transcript to the clipboard."),
			cliCommand(
				"--open-history", "history", title: "Open Transcription History",
				description: "Open Whispera's history window."),
			RaycastScriptCommand(
				fileName: "whispera-add-word.sh",
				title: "Add Word to Dictionary",
				description: "Add a name or term to Whispera's custom words; separate several with commas.",
				mode: .silent,
				argumentPlaceholder: "Word or phrase",
				body: """
					\(cli)
					"$WHISPERA" --add-word "$1" 2>&1
					"""
			),
			RaycastScriptCommand(
				fileName: "whispera-set-language.sh",
				title: "Set Dictation Language",
				description: "Switch Whispera's transcription language by name or code.",
				mode: .silent,
				argumentPlaceholder: "German or de",
				body: """
					\(linksCheck)
					\(tokenLine)
					language="$1"
					open -g "whispera://language?name=${language// /%20}&token=$token"
					"""
			),
			RaycastScriptCommand(
				fileName: "whispera-set-model.sh",
				title: "Set Whisper Model",
				description: "Switch Whispera to an already downloaded model (see List Models).",
				mode: .silent,
				argumentPlaceholder: "openai_whisper-small.en",
				body: """
					\(linksCheck)
					\(tokenLine)
					open -g "whispera://model?name=$1&token=$token"
					"""
			),
			RaycastScriptCommand(
				fileName: "whispera-list-models.sh",
				title: "List Whisper Models",
				description: "Show the models Whispera has downloaded; * marks the default.",
				mode: .fullOutput,
				argumentPlaceholder: nil,
				body: """
					\(cli)
					"$WHISPERA" --list-models
					"""
			),
			RaycastScriptCommand(
				fileName: "whispera-transcribe-file.sh",
				title: "Transcribe Audio File",
				description: "Transcribe an audio file headlessly and copy the text to the clipboard.",
				mode: .fullOutput,
				argumentPlaceholder: "Path to audio file",
				body: """
					\(cli)
					file="${1/#\\~/$HOME}"
					text="$("$WHISPERA" --transcribe-file "$file")" || exit 1
					printf '%s' "$text" | pbcopy
					printf '%s\\n' "$text"
					"""
			),
		]
	}

	/// Writes every script into `directory` as executable files, replacing older copies.
	@discardableResult
	static func export(
		to directory: URL, cliPath: String = defaultCLIPath, bundleIdentifier: String = defaultBundleIdentifier
	) throws -> [URL] {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return try commands(cliPath: cliPath, bundleIdentifier: bundleIdentifier).map { command in
			let url = directory.appendingPathComponent(command.fileName)
			try command.render().write(to: url, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
			return url
		}
	}

	/// Escapes the characters bash still interprets inside double quotes.
	static func escapeForDoubleQuotes(_ value: String) -> String {
		var escaped = ""
		for character in value {
			if "\\\"$`".contains(character) { escaped.append("\\") }
			escaped.append(character)
		}
		return escaped
	}
}
