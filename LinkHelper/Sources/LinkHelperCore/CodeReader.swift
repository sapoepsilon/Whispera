import Foundation

/// Read-only access to an agent's Git workspace for the phone's code reader
/// (`GET /v1/agents/{id}/files` and `/file`).
///
/// The phone names a path relative to the workspace root; it never names the root. The root is
/// the Git top level above the directory the agent's terminal reports. Every check that needs
/// the filesystem runs in one POSIX `sh` script, so this Mac and a saved SSH machine follow the
/// same rules: on this Mac the script runs under `/bin/sh`, on another machine under `ssh`.
struct CodeReader {
	typealias Runner = (_ script: String, _ arguments: [String], _ timeout: TimeInterval) throws -> HerdrCLI.RunResult

	static let maxFileBytes = 2 * 1024 * 1024
	static let maxListedFiles = 25_000
	static let maxPathBytes = 1024

	let run: Runner

	static let local = CodeReader { script, arguments, timeout in
		try HerdrCLI.spawn("/bin/sh", ["-c", script, "sh"] + arguments, timeout: timeout)
	}

	/// `target` is a validated SSH destination (see `AgentDirectory.sshTarget`).
	static func remote(target: String) -> CodeReader {
		CodeReader { script, arguments, timeout in
			try HerdrCLI.spawn(
				"/usr/bin/ssh",
				["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", target, remoteCommand(script, arguments)],
				timeout: timeout + 5)
		}
	}

	/// The one string `ssh` hands the remote login shell.
	static func remoteCommand(_ script: String, _ arguments: [String]) -> String {
		(["sh", "-c", script, "sh"] + arguments).map(shellQuote).joined(separator: " ")
	}

	static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

	// MARK: Path rules

	/// A clean relative path, or a 400. Absolute paths, `.`/`..`, empty components, control
	/// characters and anything over 1 KB are refused before the filesystem is consulted.
	static func validate(_ raw: String) throws -> String {
		func refuse(_ why: String) -> APIError { APIError(400, "bad_path", why) }
		guard !raw.isEmpty else { throw refuse("path is required") }
		guard raw.utf8.count <= maxPathBytes else { throw refuse("path is too long") }
		guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
			throw refuse("path contains control characters")
		}
		guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else { throw refuse("path must be relative to the workspace") }
		let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
		guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
			throw refuse("path must not contain '.', '..' or empty components")
		}
		return raw
	}

	/// Why a path is withheld by name, or nil. Matching is case-insensitive.
	static func secretReason(_ path: String) -> String? {
		let parts = path.lowercased().split(separator: "/").map(String.init)
		guard let name = parts.last else { return nil }
		if parts.contains(where: { $0.contains("secret") }) { return "secret_name" }
		if parts.dropLast().contains(where: { secretDirectories.contains($0) }) { return "secret_name" }
		if name.hasPrefix(".env") || name.hasPrefix("id_") || secretNames.contains(name) { return "secret_name" }
		if secretExtensions.contains(where: { name.hasSuffix($0) }) { return "secret_name" }
		return nil
	}

	static let secretNames: Set<String> = [".netrc", "_netrc", ".npmrc", ".pypirc", ".pgpass", ".git-credentials", "credentials"]
	static let secretDirectories: Set<String> = [".ssh", ".aws", ".gnupg", ".docker"]
	static let secretExtensions = [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".mobileprovision"]

	static func denialMessage(_ reason: String) -> String {
		switch reason {
		case "gitignored": return "This file is ignored by Git, so Whispera doesn't show it on your phone."
		default: return "This looks like a secret (keys, .env, credentials), so Whispera doesn't show it on your phone."
		}
	}

	// MARK: Language hints

	static func language(_ path: String) -> String? {
		let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
		if let exact = languageNames[name] { return exact }
		guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
		return languageExtensions[String(name[name.index(after: dot)...])]
	}

	static let languageNames: [String: String] = [
		"makefile": "makefile", "dockerfile": "dockerfile", "gemfile": "ruby", "podfile": "ruby",
		"package.swift": "swift", "cmakelists.txt": "cmake", "justfile": "just",
	]

	static let languageExtensions: [String: String] = [
		"swift": "swift", "py": "python", "pyi": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
		"jsx": "jsx", "ts": "typescript", "mts": "typescript", "tsx": "tsx", "go": "go", "rs": "rust", "rb": "ruby",
		"java": "java", "kt": "kotlin", "kts": "kotlin", "c": "c", "h": "c", "m": "objective-c", "mm": "objective-cpp",
		"cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "cs": "csharp", "php": "php", "sh": "shellscript",
		"bash": "shellscript", "zsh": "shellscript", "fish": "fish", "json": "json", "jsonc": "jsonc", "yaml": "yaml",
		"yml": "yaml", "toml": "toml", "xml": "xml", "plist": "xml", "html": "html", "htm": "html", "css": "css",
		"scss": "scss", "md": "markdown", "markdown": "markdown", "sql": "sql", "dart": "dart", "lua": "lua",
		"vue": "vue", "svelte": "svelte", "graphql": "graphql", "proto": "proto", "tf": "hcl", "hcl": "hcl",
		"ex": "elixir", "exs": "elixir", "erl": "erlang", "hs": "haskell", "scala": "scala", "zig": "zig", "nix": "nix",
		"r": "r", "pl": "perl", "ini": "ini", "cfg": "ini", "diff": "diff", "patch": "diff", "txt": "text",
	]

	// MARK: Scripts

	/// Prints `\u{1}name\n` sections; the last section of `fileScript` (`content`) is raw bytes.
	/// `$1` is the agent's directory, `$2` the relative path, `$3` the byte cap.
	static let prelude = """
		section() { printf '\\001%s\\n' "$1"; }
		fail() { section error; printf '%s' "$1"; exit 0; }
		cd -- "$1" 2>/dev/null || fail no_repository
		top=$(git rev-parse --show-toplevel 2>/dev/null) || fail no_repository
		cd -- "$top" 2>/dev/null || fail no_repository
		root=$(pwd -P)
		section root; printf '%s' "$root"
		"""

	static let filesScript = prelude + """

		section files; git -c core.quotepath=off ls-files -z --cached --others --exclude-standard 2>/dev/null | head -c 6000000
		section ignored; git ls-files -z --cached 2>/dev/null | git check-ignore --no-index -z --stdin 2>/dev/null | head -c 1000000
		section status; git status --porcelain=v1 -z --untracked-files=all 2>/dev/null | head -c 1000000
		section recent; git log -n 25 --name-only --format= -z 2>/dev/null | head -c 200000
		section branch; git rev-parse --abbrev-ref HEAD 2>/dev/null
		"""

	static let fileScript = prelude + """

		p=$2
		git check-ignore -q --no-index -- "$p" 2>/dev/null && fail gitignored
		listed=$(git ls-files -z --cached --others --exclude-standard -- ":(literal)$p" 2>/dev/null | tr '\\000' '\\n' | head -n 1)
		[ "$listed" = "$p" ] || fail not_found
		f=$root/$p
		n=0
		while [ -L "$f" ]; do
			n=$((n + 1)); [ "$n" -gt 8 ] && fail outside_root
			l=$(readlink -- "$f") || fail not_found
			case $l in /*) f=$l ;; *) f=$(dirname -- "$f")/$l ;; esac
		done
		[ -f "$f" ] || fail not_found
		d=$(cd -P -- "$(dirname -- "$f")" 2>/dev/null && pwd -P) || fail not_found
		case "$d/" in "$root"/*) ;; *) fail outside_root ;; esac
		rel=${d#"$root"}/$(basename -- "$f"); rel=${rel#/}
		section resolved; printf '%s' "$rel"
		size=$(wc -c < "$f" | tr -d ' ')
		section size; printf '%s' "$size"
		section status; git status --porcelain=v1 -z -- ":(literal)$p" 2>/dev/null | head -c 2
		section hunks
		if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
			git diff -U0 --no-color --no-ext-diff --no-textconv HEAD -- ":(literal)$p" 2>/dev/null | grep '^@@' | head -c 200000
		fi
		[ "$size" -le "$3" ] || exit 0
		section content; head -c "$3" "$f"
		"""

	static func sections(_ data: Data) -> [String: Data] {
		var out: [String: Data] = [:]
		var index = data.startIndex
		let marker: UInt8 = 1
		guard data.first == marker else { return out }
		while index < data.endIndex, data[index] == marker {
			let nameStart = data.index(after: index)
			guard let newline = data[nameStart...].firstIndex(of: 10) else { break }
			let name = String(decoding: data[nameStart..<newline], as: UTF8.self)
			let bodyStart = data.index(after: newline)
			// The raw file is last and may contain the marker byte itself.
			let end = name == "content" ? data.endIndex : (data[bodyStart...].firstIndex(of: marker) ?? data.endIndex)
			out[name] = Data(data[bodyStart..<end])
			index = end
		}
		return out
	}

	private func script(_ script: String, _ arguments: [String]) throws -> [String: Data] {
		let result = try run(script, arguments, 15)
		let parts = Self.sections(result.stdout)
		if let error = parts["error"].map({ String(decoding: $0, as: UTF8.self) }) {
			switch error {
			case "not_found": throw APIError(404, "file_not_found", "That file isn't in this workspace.")
			case "gitignored":
				throw APIError(403, "file_denied", Self.denialMessage("gitignored"), extra: ["reason": "gitignored"])
			case "outside_root":
				throw APIError(403, "file_denied", "That path leads outside the agent's workspace.", extra: ["reason": "outside_root"])
			default:
				throw APIError(409, "no_repository", "Couldn't read files. Check that this terminal is inside a Git repository.")
			}
		}
		guard parts["root"] != nil else {
			throw APIError(409, "no_repository", "Couldn't read files. Check that this terminal is inside a Git repository.")
		}
		return parts
	}

	private static func nulList(_ data: Data?) -> [String] {
		guard let data else { return [] }
		return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
	}

	/// `git status --porcelain=v1 -z`: `XY path\0`, with the source path following renames.
	static func parseStatus(_ data: Data?) -> [(path: String, status: String)] {
		let entries = nulList(data)
		var out: [(String, String)] = []
		var skip = false
		for entry in entries {
			if skip { skip = false; continue }
			guard entry.count > 3 else { continue }
			let code = Array(entry.prefix(2))
			let path = String(entry.dropFirst(3))
			let status = statusName(code)
			if status == "renamed" { skip = true }
			out.append((path, status))
		}
		return out
	}

	static func statusName(_ code: [Character]) -> String {
		if code == ["?", "?"] { return "untracked" }
		if code.contains("R") { return "renamed" }
		if code.contains("D") { return "deleted" }
		if code.contains("A") { return "added" }
		return "modified"
	}

	static func isListable(_ path: String) -> Bool {
		(try? validate(path)) != nil
	}

	// MARK: Routes

	func files(cwd: String) throws -> [String: Any] {
		let parts = try script(Self.filesScript, [cwd])
		let root = String(decoding: parts["root"] ?? Data(), as: UTF8.self)
		let changed = Self.parseStatus(parts["status"]).filter { Self.isListable($0.path) }
		let deleted = Set(changed.filter { $0.status == "deleted" }.map(\.path))
		var seen = Set<String>()
		var files: [String] = []
		for path in Self.nulList(parts["files"]) where Self.isListable(path) && !deleted.contains(path) {
			if seen.insert(path).inserted { files.append(path) }
		}
		files.sort()
		let truncated = files.count > Self.maxListedFiles
		if truncated { files = Array(files.prefix(Self.maxListedFiles)) }
		let ignored = Set(Self.nulList(parts["ignored"]))
		var denied: [[String: Any]] = []
		for path in files {
			if let reason = Self.secretReason(path) {
				denied.append(["path": path, "reason": reason])
			} else if ignored.contains(path) {
				denied.append(["path": path, "reason": "gitignored"])
			}
		}
		var recent: [String] = []
		for path in Self.nulList(parts["recent"]) where seen.contains(path) && !recent.contains(path) {
			recent.append(path)
			if recent.count == 30 { break }
		}
		let branch = String(decoding: parts["branch"] ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		return [
			"root": root, "root_name": URL(fileURLWithPath: root).lastPathComponent,
			"branch": branch.isEmpty || branch == "HEAD" ? NSNull() : branch,
			"files": files, "changed": changed.map { ["path": $0.path, "status": $0.status] }, "recent": recent,
			"denied": denied, "truncated": truncated, "max_file_bytes": Self.maxFileBytes,
		]
	}

	func file(cwd: String, path raw: String) throws -> [String: Any] {
		let path = try Self.validate(raw)
		if let reason = Self.secretReason(path) {
			throw APIError(403, "file_denied", Self.denialMessage(reason), extra: ["reason": reason, "path": path])
		}
		let parts = try script(Self.fileScript, [cwd, path, String(Self.maxFileBytes)])
		let resolved = String(decoding: parts["resolved"] ?? Data(), as: UTF8.self)
		// A symlink inside the workspace may still point at a secret by another name.
		if let reason = Self.secretReason(resolved) {
			throw APIError(403, "file_denied", Self.denialMessage(reason), extra: ["reason": reason, "path": path])
		}
		guard let size = Int(String(decoding: parts["size"] ?? Data(), as: UTF8.self)) else {
			throw APIError(404, "file_not_found", "That file isn't in this workspace.")
		}
		guard size <= Self.maxFileBytes, let raw = parts["content"] else {
			throw APIError(
				413, "file_too_large", "This file is over \(Self.maxFileBytes / 1024 / 1024) MB, too large to show on your phone.",
				extra: ["size": size, "max_bytes": Self.maxFileBytes])
		}
		let code = String(decoding: parts["status"] ?? Data(), as: UTF8.self)
		let status = code.count == 2 ? Self.statusName(Array(code)) : nil
		var answer: [String: Any] = [
			"path": path, "size": size, "language": Self.language(resolved.isEmpty ? path : resolved) ?? NSNull(),
			"status": status ?? NSNull(), "max_file_bytes": Self.maxFileBytes,
		]
		let probe = raw.prefix(8192)
		if probe.contains(0) || String(data: raw, encoding: .utf8) == nil {
			answer["binary"] = true
			answer["content"] = NSNull()
			answer["hunks"] = []
			return answer
		}
		let text = String(decoding: raw, as: UTF8.self)
		var lines = text.reduce(into: 0) { count, character in if character == "\n" { count += 1 } }
		if !text.isEmpty && !text.hasSuffix("\n") { lines += 1 }
		answer["binary"] = false
		answer["content"] = text
		answer["lines"] = lines
		answer["hunks"] =
			status == "untracked" || status == "added"
			? (lines > 0 ? [["start": 1, "count": lines, "kind": "add"]] : [])
			: Self.parseHunks(String(decoding: parts["hunks"] ?? Data(), as: UTF8.self))
		return answer
	}

	/// `@@ -a,b +c,d @@` headers from `git diff -U0` → new-side ranges. A pure deletion (d = 0)
	/// marks line c, the one the removed text followed.
	static func parseHunks(_ text: String) -> [[String: Any]] {
		var out: [[String: Any]] = []
		for line in text.split(separator: "\n") where line.hasPrefix("@@") {
			let fields = line.split(separator: " ")
			guard fields.count >= 3 else { continue }
			func range(_ field: Substring) -> (Int, Int)? {
				let numbers = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
				guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
				let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
				return (start, count)
			}
			guard let old = range(fields[1]), let new = range(fields[2]) else { continue }
			let kind = new.1 == 0 ? "delete" : (old.1 == 0 ? "add" : "change")
			out.append(["start": max(1, new.0), "count": new.1, "kind": kind])
		}
		return out
	}
}
