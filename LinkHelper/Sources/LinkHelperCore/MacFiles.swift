import Darwin
import Foundation
import WhisperaHerdr

/// `GET /v1/agents/{id}/mac-file?path=/abs/path`: one image, HTML, PDF or text file an agent
/// mentioned by absolute path, for the phone's link previews (capability `mac_files`).
///
/// Only files under a short allowlist of roots are served: the agent's working directory and
/// its Git top level, the per-user temporary directory (`$TMPDIR`, never the world-writable
/// /private/tmp, where any local user could plant a file) and ~/Downloads. Symlinks are
/// resolved before any root or name is checked, the resolved file is opened without following a
/// final link, and the path of what was actually opened is checked again, so a directory swapped
/// for a link between the check and the open is caught. Secret-looking names are refused by the
/// same rules as the code reader.
struct MacFiles {
	enum Kind: String {
		case image, html, pdf, text
	}

	static let maxPathBytes = 1024

	/// Extension → kind and the content type it is served with.
	static let types: [String: (kind: Kind, contentType: String)] = [
		"png": (.image, "image/png"), "jpg": (.image, "image/jpeg"), "jpeg": (.image, "image/jpeg"),
		"gif": (.image, "image/gif"), "webp": (.image, "image/webp"), "heic": (.image, "image/heic"),
		"heif": (.image, "image/heif"),
		"html": (.html, "text/html; charset=utf-8"), "htm": (.html, "text/html; charset=utf-8"),
		"pdf": (.pdf, "application/pdf"), "txt": (.text, "text/plain; charset=utf-8"),
	]

	static func maxBytes(_ kind: Kind) -> Int {
		switch kind {
		case .image: return 20 * 1024 * 1024
		case .pdf: return 20 * 1024 * 1024
		case .html: return 5 * 1024 * 1024
		case .text: return 2 * 1024 * 1024
		}
	}

	struct Served {
		var data: Data
		var kind: Kind
		var contentType: String
		var size: Int
	}

	/// Real paths (symlinks resolved, no trailing slash) a served file must sit under.
	let roots: [String]

	init(roots: [String]) {
		self.roots = roots
	}

	/// The allowlist for an agent whose terminal reports `cwd`. A working directory that is `/`,
	/// the home folder or one of its ancestors adds nothing: it would open the whole disk.
	static func allowlist(cwd: String?, gitTopLevel: String?, home: String = NSHomeDirectory(),
		temporary: String = NSTemporaryDirectory()) -> MacFiles
	{
		let realHome = realPath(home) ?? home
		var candidates: [String] = []
		for workspace in [cwd, gitTopLevel].compactMap({ $0 }) {
			guard let real = realPath(workspace), isNarrow(real, home: realHome) else { continue }
			candidates.append(real)
		}
		candidates += [temporary, (realHome as NSString).appendingPathComponent("Downloads")]
			.compactMap(realPath)
		var seen = Set<String>()
		return MacFiles(roots: candidates.filter { seen.insert($0).inserted })
	}

	/// A workspace root that is a real directory below the home folder's level, not `/`,
	/// `/Users`, the home folder itself, or a system or library folder.
	static func isNarrow(_ real: String, home: String) -> Bool {
		guard real.hasPrefix("/"), real != "/" else { return false }
		if real == home || (home + "/").hasPrefix(real + "/") { return false }
		let lowered = real.lowercased()
		for system in ["/system", "/library", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/var", "/private/var/db"]
		where lowered == system || lowered.hasPrefix(system + "/") {
			// The per-user temporary folder lives under /private/var/folders and is allowed separately.
			return false
		}
		if lowered.hasPrefix(home.lowercased() + "/library") { return false }
		return true
	}

	static func realPath(_ path: String) -> String? {
		guard let resolved = Darwin.realpath(path, nil) else { return nil }
		defer { free(resolved) }
		let value = String(cString: resolved)
		return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
	}

	// MARK: Rules

	static func refuse(_ reason: String, _ message: String, status: Int = 403) -> APIError {
		APIError(status, "file_denied", message, extra: ["reason": reason])
	}

	/// A clean absolute path (a leading `~/` means the home folder), or a 400.
	static func validate(_ raw: String, home: String = NSHomeDirectory()) throws -> String {
		func bad(_ why: String) -> APIError { APIError(400, "bad_path", why) }
		guard !raw.isEmpty else { throw bad("path is required") }
		guard raw.utf8.count <= maxPathBytes else { throw bad("path is too long") }
		guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
			throw bad("path contains control characters")
		}
		let path = raw.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(raw.dropFirst(2))) : raw
		guard path.hasPrefix("/") else { throw bad("path must be absolute") }
		let parts = path.split(separator: "/", omittingEmptySubsequences: true)
		guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw bad("path must not contain '.' or '..'") }
		return path
	}

	/// Why a path is withheld by name: the code reader's secret rules plus keychains.
	static func secretReason(_ path: String) -> String? {
		if let reason = CodeReader.secretReason(path) { return reason }
		let lowered = path.lowercased()
		if lowered.split(separator: "/").contains(where: { $0 == "keychains" || $0.hasSuffix(".keychain") || $0.hasSuffix(".keychain-db") }) {
			return "secret_name"
		}
		return nil
	}

	static func type(of path: String) -> (kind: Kind, contentType: String)? {
		let name = (path as NSString).lastPathComponent.lowercased()
		guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
		return types[String(name[name.index(after: dot)...])]
	}

	func isAllowed(_ real: String) -> Bool {
		roots.contains { real == $0 || real.hasPrefix($0 == "/" ? "/" : $0 + "/") }
	}

	/// Checks `raw` and reads it. Every refusal names its `reason`.
	func read(_ raw: String) throws -> Served {
		let path = try Self.validate(raw)
		if let reason = Self.secretReason(path) {
			throw Self.refuse(reason, CodeReader.denialMessage(reason))
		}
		guard Self.type(of: path) != nil else {
			throw Self.refuse("unsupported_type", "Only images, HTML, PDF and text files can be shown on your phone.", status: 415)
		}
		guard let real = Self.realPath(path) else {
			throw APIError(404, "file_not_found", "That file isn't on your Mac anymore.")
		}
		// A link with an innocent name may still point at a secret, or at another kind of file.
		if let reason = Self.secretReason(real) {
			throw Self.refuse(reason, CodeReader.denialMessage(reason))
		}
		guard let type = Self.type(of: real) else {
			throw Self.refuse("unsupported_type", "Only images, HTML, PDF and text files can be shown on your phone.", status: 415)
		}
		guard isAllowed(real) else {
			throw Self.refuse(
				"outside_allowed",
				"Whispera only shows files from the agent's workspace, temporary folders and Downloads.")
		}
		let fd = Darwin.open(real, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		guard fd >= 0 else {
			if errno == ELOOP { throw Self.refuse("outside_allowed", "That file changed while it was being read.") }
			throw APIError(404, "file_not_found", "That file isn't on your Mac anymore.")
		}
		defer { Darwin.close(fd) }
		guard let opened = Self.openedPath(fd), isAllowed(opened), Self.secretReason(opened) == nil,
			Self.type(of: opened)?.kind == type.kind
		else {
			throw Self.refuse("outside_allowed", "That file changed while it was being read.")
		}
		var info = stat()
		guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
			throw APIError(404, "file_not_found", "That isn't a file.")
		}
		let size = Int(info.st_size)
		let cap = Self.maxBytes(type.kind)
		guard size <= cap else {
			throw APIError(
				413, "file_too_large", "This file is over \(cap / 1024 / 1024) MB, too large to show on your phone.",
				extra: ["size": size, "max_bytes": cap])
		}
		let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
		let data = (try handle.read(upToCount: cap + 1)) ?? Data()
		guard data.count <= cap else {
			throw APIError(413, "file_too_large", "This file grew too large to show on your phone.", extra: ["max_bytes": cap])
		}
		if type.kind == .image, !Self.looksLikeImage(data) {
			throw Self.refuse("unsupported_type", "That file isn't an image.", status: 415)
		}
		return Served(data: data, kind: type.kind, contentType: type.contentType, size: data.count)
	}

	/// Where an open descriptor really points (`F_GETPATH`), symlinks already resolved.
	static func openedPath(_ fd: Int32) -> String? {
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
		return String(cString: buffer)
	}

	/// PNG, JPEG, GIF, WebP or HEIF by their leading bytes, so a renamed file is not served as one.
	static func looksLikeImage(_ data: Data) -> Bool {
		let bytes = [UInt8](data.prefix(12))
		func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix }
		if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8)) { return true }
		if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
		if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) { return true }
		return false
	}

	/// Headers that keep a served file inert if it is ever opened outside the app.
	static func headers(_ served: Served) -> [(String, String)] {
		var headers: [(String, String)] = [
			("X-Content-Type-Options", "nosniff"), ("Cache-Control", "private, no-store"),
			("Content-Disposition", served.kind == .html || served.kind == .text ? "attachment" : "inline"),
		]
		if served.kind == .html { headers.append(("Content-Security-Policy", "sandbox; default-src 'none'; img-src data:; style-src 'unsafe-inline'")) }
		return headers
	}
}

extension AgentDirectory {
	/// The file server for a local agent's mention of `path`. Remote agents' paths are on
	/// another machine, which this route does not reach.
	func macFiles(_ id: String) throws -> MacFiles {
		var remote = HerdrCoreID.isRemote(id)
		if case .remote = AgentRef(id) { remote = true }
		if remote {
			throw APIError(409, "remote_machine", "Files on another machine can't be previewed yet.")
		}
		let cwd = try? workingDirectory(id)
		var top: String?
		if let cwd {
			let git = GitSafety.envCommand(["-C", cwd, "rev-parse", "--show-toplevel"])
			let result = try? HerdrCLI.spawn(git.path, git.arguments, timeout: 5)
			if let result, result.status == 0 {
				let line = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
				if line.hasPrefix("/") { top = line }
			}
		}
		return MacFiles.allowlist(cwd: cwd, gitTopLevel: top)
	}
}
