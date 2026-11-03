import Foundation

/// The phone's Changes screen (`GET /v1/agents/{id}/diff`): every changed file in the agent's
/// repository as one Git patch, whatever subdirectory the terminal sits in.
///
/// - `all` (the default, `staged=0`): staged and unstaged changes against `HEAD`, plus
///   untracked files as new files, like `git status` shows them.
/// - `unstaged`: the work tree against the index, plus untracked files.
/// - `staged` (`staged=1`): the index against `HEAD`.
///
/// Nothing is dropped: a file too large to send, a secret-named untracked file, or a file past
/// the patch budget still gets its `diff --git` header, followed by a
/// `whispera-omitted: <reason> <bytes>` line the phone shows instead of the hunks. A file left
/// out for the budget can be fetched on its own with `?path=`. The scripts run under `/bin/sh`
/// here and under `ssh` on a saved machine, like `CodeReader`.
///
/// The work is bounded so a messy work tree answers inside the phone's timeout: untracked
/// files are read by one `git diff` over a throwaway index (`git add -N`), an untracked folder
/// with more than `maxUntrackedPerFolder` files is listed as one entry, and when the patch does
/// not finish inside `budget` the file list goes back alone with `partial` set.
struct RepositoryDiff {
	enum Scope: String { case all, unstaged, staged }

	static let maxFileBytes = 512 * 1024
	static let maxPatchBytes = 4 * 1024 * 1024
	static let maxUntrackedDiffs = 300
	static let maxUntrackedListed = 2000
	static let maxUntrackedPerFolder = 200
	static let maxUntrackedNameBytes = 8_000_000
	/// The whole request, under the phone's 10 s request timeout with room for the relay.
	static let budget: TimeInterval = 7
	static let cacheTTL: TimeInterval = 10
	static let omittedMarker = "whispera-omitted: "

	let run: CodeReader.Runner
	var budget: TimeInterval = Self.budget

	init(_ reader: CodeReader) { run = reader.run }
	init(run: @escaping CodeReader.Runner) { self.run = run }

	/// `$1` the agent's directory, `$2` the scope. Lists, without reading any file: the root,
	/// `HEAD`, the index's mtime, the tracked names, then the untracked entries twice, folded
	/// into whole untracked folders (`folders`) and file by file (`untracked`).
	static let listScript = """
		section() { printf '\\001%s\\n' "$1"; }
		fail() { section error; printf '%s' "$1"; exit 0; }
		cd -- "$1" 2>/dev/null || fail no_repository
		top=$(git rev-parse --show-toplevel 2>/dev/null) || fail no_repository
		cd -- "$top" 2>/dev/null || fail no_repository
		export GIT_OPTIONAL_LOCKS=0
		scope=$2
		section root; pwd -P
		head=$(git rev-parse -q --verify HEAD 2>/dev/null) || head=
		section head; printf '%s' "$head"
		index=$(git rev-parse --git-path index 2>/dev/null)
		section stamp; stat -c %Y "$index" 2>/dev/null || stat -f %m "$index" 2>/dev/null
		case $scope in
			staged) set -- --cached ;;
			unstaged) set -- ;;
			*) set -- "${head:-$(git hash-object -t tree /dev/null)}" ;;
		esac
		section names; git -c core.quotepath=off --no-pager diff -M --no-ext-diff --name-only -z "$@" -- 2>/dev/null | head -c 2000000
		[ "$scope" = staged ] && exit 0
		section folders; git -c core.quotepath=off ls-files -z --others --exclude-standard --directory --no-empty-directory 2>/dev/null | head -c 2000000
		section untracked; git -c core.quotepath=off ls-files -z --others --exclude-standard 2>/dev/null | head -c \(maxUntrackedNameBytes)
		"""

	/// `$1` the root, `$2` the per-file cap, then `./`-prefixed untracked paths. Names the ones
	/// Git should not read (`skip`: gone or unreadable; `large`: over the cap, with `sizes`
	/// from `wc -c`) in a handful of processes, without opening any file.
	static let measureScript = """
		section() { printf '\\001%s\\n' "$1"; }
		cd -- "$1" 2>/dev/null || exit 0
		cap=$2; shift 2
		section skip
		for p in "$@"; do
			[ -L "$p" ] && continue
			if [ ! -e "$p" ]; then printf 'gone %s\\000' "$p"; elif [ ! -r "$p" ]; then printf 'unreadable %s\\000' "$p"; fi
		done
		section large; find "$@" -prune -type f -size +"$cap"c -print0 2>/dev/null
		section sizes; find "$@" -prune -type f -size +"$cap"c -exec wc -c {} + 2>/dev/null
		"""

	/// `$1` the root, `$2` the scope, `$3` the byte cap for the patch, then the `./`-prefixed
	/// untracked files to show. They are marked intent-to-add in a copy of the index, so one
	/// `git diff` prints them with the tracked changes; the real index is never written.
	static let patchScript = """
		section() { printf '\\001%s\\n' "$1"; }
		cd -- "$1" 2>/dev/null || exit 0
		scope=$2; cap=$3; shift 3
		export GIT_OPTIONAL_LOCKS=0
		tmpdir=${TMPDIR:-/tmp}
		find "$tmpdir" -maxdepth 1 -name 'whispera-diff.*' -mmin +10 -exec rm -rf {} + 2>/dev/null
		if [ $# -gt 0 ]; then
			index=$(git rev-parse --git-path index 2>/dev/null)
			if work=$(mktemp -d "$tmpdir/whispera-diff.XXXXXX" 2>/dev/null); then
				trap 'rm -rf "$work"' EXIT
				[ -f "$index" ] && cp "$index" "$work/index"
				if GIT_INDEX_FILE="$work/index" GIT_LITERAL_PATHSPECS=1 git add -N -- "$@" >/dev/null 2>&1; then
					export GIT_INDEX_FILE="$work/index"
					section added
				fi
			fi
		fi
		case $scope in
			staged) set -- --cached ;;
			unstaged) set -- ;;
			*) head=$(git rev-parse -q --verify HEAD 2>/dev/null) || head=$(git hash-object -t tree /dev/null); set -- "$head" ;;
		esac
		section names; git -c core.quotepath=off --no-pager diff -M --no-ext-diff --name-only -z "$@" -- 2>/dev/null | head -c 2000000
		section patch; git -c core.quotepath=off --no-pager diff -M --no-ext-diff --no-textconv --no-color "$@" -- 2>/dev/null | head -c "$cap"
		"""

	/// `$1` the agent's directory, `$2` the scope, `$3` one path from the root, `$4` the
	/// per-file cap, `$5` the byte cap. One file's patch, for a file the list left out.
	static let fileScript = """
		section() { printf '\\001%s\\n' "$1"; }
		fail() { section error; printf '%s' "$1"; exit 0; }
		cd -- "$1" 2>/dev/null || fail no_repository
		top=$(git rev-parse --show-toplevel 2>/dev/null) || fail no_repository
		cd -- "$top" 2>/dev/null || fail no_repository
		export GIT_OPTIONAL_LOCKS=0 GIT_LITERAL_PATHSPECS=1
		scope=$2; p=$3; big=$4; cap=$5
		if [ "$scope" != staged ] && [ "$(git -c core.quotepath=off ls-files --others --exclude-standard -- "$p" 2>/dev/null)" = "$p" ]; then
			section untracked
			if [ ! -L "$p" ]; then
				[ -r "$p" ] || { section unreadable; exit 0; }
				if [ -n "$(find "./$p" -prune -type f -size +"$big"c -print 2>/dev/null)" ]; then section large; wc -c < "$p" | tr -d ' '; exit 0; fi
			fi
			if work=$(mktemp -d "${TMPDIR:-/tmp}/whispera-diff.XXXXXX" 2>/dev/null); then
				trap 'rm -rf "$work"' EXIT
				index=$(git rev-parse --git-path index 2>/dev/null)
				[ -f "$index" ] && cp "$index" "$work/index"
				export GIT_INDEX_FILE="$work/index"
				git add -N -- "$p" >/dev/null 2>&1 || { section unreadable; exit 0; }
			fi
		fi
		case $scope in
			staged) set -- --cached ;;
			unstaged) set -- ;;
			*) head=$(git rev-parse -q --verify HEAD 2>/dev/null) || head=$(git hash-object -t tree /dev/null); set -- "$head" ;;
		esac
		section patch; git -c core.quotepath=off --no-pager diff --no-ext-diff --no-textconv --no-color "$@" -- "$p" 2>/dev/null | head -c "$cap"
		"""

	// MARK: Changes

	func changes(cwd: String, scope: Scope, refresh: Bool = false) throws -> [String: Any] {
		let started = Date()
		func left() -> TimeInterval { budget - Date().timeIntervalSince(started) }
		let listing = CodeReader.sections(try run(Self.listScript, [cwd, scope.rawValue], max(1, left())).stdout)
		guard listing["error"] == nil, let rootData = listing["root"] else { throw Self.noRepository }
		let root = Self.text(rootData)
		let names = Self.nulList(listing["names"])
		let raw = listing["untracked"] ?? Data()
		let everyUntracked = scope == .staged ? [] : Self.nulList(raw)
		let listedEveryName = raw.count < Self.maxUntrackedNameBytes
		let entries = scope == .staged
			? [] : Self.untrackedEntries(folders: Self.nulList(listing["folders"]), files: everyUntracked, complete: listedEveryName)

		let key = Self.cacheKey(
			[root, scope.rawValue, Self.text(listing["head"]), Self.text(listing["stamp"])],
			listing["names"], listing["folders"], raw)
		if !refresh, let cached = Self.cache.value(key) {
			var answer = cached
			answer["cached"] = true
			answer["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1000)
			return answer
		}

		let shown = Array(entries.prefix(Self.maxUntrackedListed))
		var partialReason: String? = entries.count > shown.count || !listedEveryName ? "untracked_limit" : nil
		var reasons: [String: Omission] = [:]
		var candidates: [String] = []
		for entry in shown {
			switch entry.kind {
			case .repository: reasons[entry.path] = Omission("repository", nil)
			case .folder(let count): reasons[entry.path] = Omission("folder", count)
			case .file:
				if CodeReader.secretReason(entry.path) != nil { reasons[entry.path] = Omission("secret", nil) }
				else if candidates.count < Self.maxUntrackedDiffs { candidates.append(entry.path) }
				else { reasons[entry.path] = Omission("limit", nil) }
			}
		}

		var readable = candidates
		var gone: Set<String> = []
		if !candidates.isEmpty, root.hasPrefix("/") {
			do {
				let measured = try measure(root: root, paths: candidates, timeout: max(0.5, left()))
				gone = measured.gone
				reasons.merge(measured.reasons) { first, _ in first }
				readable = candidates.filter { measured.reasons[$0] == nil && !measured.gone.contains($0) }
			} catch let error as APIError where error.status == 504 {
				for path in candidates { reasons[path] = Omission("limit", nil) }
				readable = []
				partialReason = "time"
			}
		}

		var text = ""
		var shownUntracked: Set<String> = []
		var files = 0
		let untrackedSet = Set(everyUntracked)
		do {
			guard left() > 0.2 else { throw APIError(504, "diff_timeout", "out of time") }
			let result = try run(
				Self.patchScript, [root, scope.rawValue, String(Self.maxPatchBytes + 1)] + readable.map { "./" + $0 },
				max(0.5, left()))
			let parts = CodeReader.sections(result.stdout)
			if parts["added"] != nil { shownUntracked = Set(readable) }
			let all = Self.nulList(parts["names"])
			let tracked = Self.trackedPatch(parts["patch"] ?? Data(), names: all, newFiles: untrackedSet)
			text = tracked.text
			files = tracked.files
			// `git add -N` refused the set (a file vanished or turned unreadable since).
			if parts["added"] == nil { for path in readable { reasons[path] = Omission("limit", nil) } }
		} catch let error as APIError where error.status == 504 {
			// Out of time: every file still goes back, by name, for the phone to fetch one by one.
			partialReason = "time"
			for name in names { text += Self.omitted(Self.gitHeader(name), reason: "limit", bytes: nil) }
			files = names.count
			for path in readable { reasons[path] = Omission("limit", nil) }
		}

		var untrackedListed = 0
		for entry in shown where !gone.contains(entry.path) {
			untrackedListed += 1
			if shownUntracked.contains(entry.path) { continue }
			let omission = reasons[entry.path] ?? Omission("limit", nil)
			text += Self.omitted(Self.gitHeader(entry.path, new: true), reason: omission.reason, bytes: omission.bytes)
			files += 1
		}

		var answer: [String: Any] = [
			"patch": text, "staged": scope == .staged, "scope": scope.rawValue, "files": files,
			"untracked": untrackedListed, "untracked_total": everyUntracked.count,
			"truncated": partialReason != nil || text.contains("\n" + Self.omittedMarker),
			"partial": partialReason != nil, "max_file_bytes": Self.maxFileBytes,
		]
		if let partialReason { answer["partial_reason"] = partialReason }
		if partialReason != "time" { Self.cache.store(key, answer) }
		answer["cached"] = false
		answer["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1000)
		return answer
	}

	/// One file's patch (`?path=`), for a file the list left out for its budget. A secret's
	/// name and a file over the cap answer with the omitted line, like the list.
	func file(cwd: String, scope: Scope, path raw: String) throws -> [String: Any] {
		let path = try CodeReader.validate(raw)
		var answer: [String: Any] = ["path": path, "scope": scope.rawValue, "staged": scope == .staged, "max_file_bytes": Self.maxFileBytes]
		if CodeReader.secretReason(path) != nil {
			answer["patch"] = Self.omitted(Self.gitHeader(path, new: true), reason: "secret", bytes: nil)
			return answer
		}
		let parts = CodeReader.sections(try run(
			Self.fileScript, [cwd, scope.rawValue, path, String(Self.maxFileBytes), String(Self.maxFileBytes + 64 * 1024)], budget).stdout)
		guard parts["error"] == nil else { throw Self.noRepository }
		let untracked = parts["untracked"] != nil
		if parts["unreadable"] != nil {
			answer["patch"] = Self.omitted(Self.gitHeader(path, new: true), reason: "unreadable", bytes: nil)
		} else if let large = parts["large"] {
			answer["patch"] = Self.omitted(Self.gitHeader(path, new: true), reason: "too_large", bytes: Int(Self.text(large)))
		} else {
			let block = Self.splitFiles(String(decoding: parts["patch"] ?? Data(), as: UTF8.self)).first ?? ""
			answer["patch"] = block.utf8.count > Self.maxFileBytes
				? Self.omitted(Self.header(of: block), reason: "too_large", bytes: block.utf8.count) : block
		}
		answer["untracked"] = untracked
		return answer
	}

	static let noRepository = APIError(409, "no_repository", "Couldn't read changes. Check that this terminal is inside a Git repository.")

	// MARK: Untracked entries

	struct Omission: Equatable {
		var reason: String
		var bytes: Int?
		init(_ reason: String, _ bytes: Int?) { self.reason = reason; self.bytes = bytes }
	}

	struct UntrackedEntry: Equatable {
		enum Kind: Equatable { case file, repository, folder(Int?) }
		var path: String
		var kind: Kind
	}

	/// The untracked entries in Git's order: `folders` is `ls-files --directory` (whole untracked
	/// folders end in `/`), `files` the same walk file by file. A folder keeps its files unless
	/// it holds more than `maxUntrackedPerFolder`; a folder `files` names itself is a nested
	/// repository. When `files` was cut short, a folder with none of its files listed is folded.
	static func untrackedEntries(folders: [String], files: [String], complete: Bool) -> [UntrackedEntry] {
		let folderSet = Set(folders.filter { $0.hasSuffix("/") })
		var inFolder: [String: [String]] = [:]
		var repositories: Set<String> = []
		for file in files {
			if folderSet.contains(file) { repositories.insert(file); continue }
			var index = file.startIndex
			while let slash = file[index...].firstIndex(of: "/") {
				let prefix = String(file[...slash])
				if folderSet.contains(prefix) { inFolder[prefix, default: []].append(file); break }
				index = file.index(after: slash)
			}
		}
		var entries: [UntrackedEntry] = []
		for entry in folders {
			guard entry.hasSuffix("/") else { entries.append(UntrackedEntry(path: entry, kind: .file)); continue }
			let name = String(entry.dropLast())
			if repositories.contains(entry) { entries.append(UntrackedEntry(path: name, kind: .repository)); continue }
			let inside = inFolder[entry] ?? []
			if inside.count > maxUntrackedPerFolder || (inside.isEmpty && !complete) {
				entries.append(UntrackedEntry(path: name, kind: .folder(complete ? inside.count : nil)))
			} else {
				entries += inside.map { UntrackedEntry(path: $0, kind: .file) }
			}
		}
		return entries
	}

	/// Which of `paths` Git should not read, without opening any of them.
	func measure(root: String, paths: [String], timeout: TimeInterval) throws -> (reasons: [String: Omission], gone: Set<String>) {
		let parts = CodeReader.sections(try run(Self.measureScript, [root, String(Self.maxFileBytes)] + paths.map { "./" + $0 }, timeout).stdout)
		func strip(_ path: String) -> String { path.hasPrefix("./") ? String(path.dropFirst(2)) : path }
		var reasons: [String: Omission] = [:]
		var gone: Set<String> = []
		for record in Self.nulList(parts["skip"]) {
			guard let space = record.firstIndex(of: " ") else { continue }
			let path = strip(String(record[record.index(after: space)...]))
			if record[..<space] == "gone" { gone.insert(path) } else { reasons[path] = Omission("unreadable", nil) }
		}
		var sizes: [String: Int] = [:]
		for line in String(decoding: parts["sizes"] ?? Data(), as: UTF8.self).split(separator: "\n") {
			let trimmed = line.drop { $0 == " " }
			guard let space = trimmed.firstIndex(of: " "), let size = Int(trimmed[..<space]) else { continue }
			sizes[strip(String(trimmed[trimmed.index(after: space)...]))] = size
		}
		for path in Self.nulList(parts["large"]).map(strip) { reasons[path] = Omission("too_large", sizes[path]) }
		return (reasons, gone)
	}

	// MARK: Tracked changes

	/// The patch, file by file: a file over the cap keeps its header and an omitted line;
	/// files the byte budget cut off get a header from `--name-only`, which lists them in the
	/// same order (as new files when `newFiles` holds them).
	static func trackedPatch(_ data: Data, names: [String], newFiles: Set<String> = []) -> (text: String, files: Int) {
		let cut = data.count > maxPatchBytes
		var blocks = splitFiles(String(decoding: data.prefix(maxPatchBytes), as: UTF8.self))
		// A cut patch ends inside its last file: that file is shown as omitted.
		if cut, !blocks.isEmpty { blocks[blocks.count - 1] = omitted(header(of: blocks[blocks.count - 1]), reason: "limit", bytes: nil) }
		var text = ""
		for block in blocks {
			text += block.utf8.count > maxFileBytes ? omitted(header(of: block), reason: "too_large", bytes: block.utf8.count) : block
		}
		if names.count > blocks.count {
			for name in names[blocks.count...] { text += omitted(gitHeader(name, new: newFiles.contains(name)), reason: "limit", bytes: nil) }
		}
		return (text, max(blocks.count, names.count))
	}

	/// Splits a Git patch at each `diff --git` line; each block ends with a newline.
	static func splitFiles(_ patch: String) -> [String] {
		guard !patch.isEmpty else { return [] }
		var blocks: [String] = []
		var current = ""
		for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
			if line.hasPrefix("diff --git "), !current.isEmpty { blocks.append(current); current = "" }
			current += line + "\n"
		}
		if current != "\n" && !current.isEmpty {
			// `split` adds an empty piece after the patch's last newline.
			blocks.append(current.hasSuffix("\n\n") ? String(current.dropLast()) : current)
		}
		return blocks
	}

	/// A block's header lines: everything before its first hunk or binary note.
	static func header(of block: String) -> String {
		var lines: [Substring] = []
		for line in block.split(separator: "\n") {
			if line.hasPrefix("@@") || line.hasPrefix("Binary files ") || line.hasPrefix("--- ") || line.hasPrefix("GIT binary patch") { break }
			lines.append(line)
		}
		return lines.joined(separator: "\n") + "\n"
	}

	static func omitted(_ header: String, reason: String, bytes: Int?) -> String {
		header + omittedMarker + reason + (bytes.map { " \($0)" } ?? "") + "\n"
	}

	/// `diff --git a/<path> b/<path>`, quoting a path the way Git does when it must.
	static func gitHeader(_ path: String, new: Bool = false) -> String {
		let needsQuote = path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\"" || $0 == "\\" }
		func side(_ prefix: String) -> String {
			guard needsQuote else { return prefix + path }
			var out = "\""
			for scalar in (prefix + path).unicodeScalars {
				switch scalar {
				case "\"": out += "\\\""
				case "\\": out += "\\\\"
				case "\n": out += "\\n"
				case "\t": out += "\\t"
				default:
					if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\%03o", scalar.value) } else { out.unicodeScalars.append(scalar) }
				}
			}
			return out + "\""
		}
		return "diff --git \(side("a/")) \(side("b/"))\n" + (new ? "new file mode 100644\n" : "")
	}

	static func nulList(_ data: Data?) -> [String] {
		guard let data else { return [] }
		return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
	}

	static func text(_ data: Data?) -> String {
		String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: Cache

	/// The last answers, keyed by the root, scope, `HEAD`, the index's mtime and the changed
	/// and untracked names. An edit inside an already-changed file keeps the key, so entries
	/// live `cacheTTL` seconds and the phone's Refresh skips the cache.
	static let cache = Cache()

	static func cacheKey(_ fields: [String], _ lists: Data?...) -> String {
		var hasher = Hasher()
		for list in lists { hasher.combine(list ?? Data()) }
		return fields.joined(separator: "\u{1}") + "\u{1}\(hasher.finalize())"
	}

	final class Cache: @unchecked Sendable {
		private let lock = NSLock()
		private var entries: [String: (at: Date, value: [String: Any])] = [:]

		func value(_ key: String) -> [String: Any]? {
			lock.lock()
			defer { lock.unlock() }
			guard let entry = entries[key], Date().timeIntervalSince(entry.at) < RepositoryDiff.cacheTTL else { return nil }
			return entry.value
		}

		func store(_ key: String, _ value: [String: Any]) {
			lock.lock()
			defer { lock.unlock() }
			let now = Date()
			entries = entries.filter { now.timeIntervalSince($0.value.at) < RepositoryDiff.cacheTTL }
			if entries.count >= 16 { entries.removeAll() }
			entries[key] = (now, value)
		}

		func removeAll() {
			lock.lock()
			entries.removeAll()
			lock.unlock()
		}
	}
}
