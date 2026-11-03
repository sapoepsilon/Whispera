import Foundation

/// Atomic, owner-only files (PROTOCOL §1.2): write a temp file, fsync, rename, mode 0600.
enum FileStore {
	static func ensureDirectory(_ path: String, mode: mode_t = 0o700) throws {
		try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
		guard chmod(path, mode) == 0 else { throw posixError("chmod \(path)") }
	}

	static func writeAtomic(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
		let directory = (path as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
		var template = Array((directory + "/.tmp-XXXXXX").utf8CString)
		let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
		guard fd >= 0 else { throw posixError("mkstemp in \(directory)") }
		let tmp = String(cString: template)
		var ok = false
		defer {
			if !ok { unlink(tmp) }
		}
		guard fchmod(fd, mode) == 0 else {
			close(fd)
			throw posixError("fchmod")
		}
		let written = data.withUnsafeBytes { buffer -> Bool in
			var offset = 0
			while offset < buffer.count {
				let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
				if n <= 0 { return false }
				offset += n
			}
			return true
		}
		guard written, fsync(fd) == 0 else {
			close(fd)
			throw posixError("write \(path)")
		}
		close(fd)
		guard rename(tmp, path) == 0 else { throw posixError("rename \(path)") }
		ok = true
		let dirFD = open(directory, O_RDONLY)
		if dirFD >= 0 {
			fsync(dirFD)
			close(dirFD)
		}
	}

	static func writeJSONAtomic(_ object: Any, to path: String) throws {
		var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
		data.append(0x0A)
		try writeAtomic(data, to: path)
	}

	static func readJSON(_ path: String) throws -> Any? {
		guard FileManager.default.fileExists(atPath: path) else { return nil }
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		return try JSONSerialization.jsonObject(with: data)
	}

	static func posixError(_ what: String) -> NSError {
		NSError(
			domain: NSPOSIXErrorDomain, code: Int(errno),
			userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
	}
}

/// Compact JSON for wire bodies. Keys sorted so bodies are stable across runs.
enum WireJSON {
	static func encode(_ object: Any) -> Data {
		(try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
			?? Data("{}".utf8)
	}

	static func decodeObject(_ data: Data) -> [String: Any]? {
		(try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
	}

	/// An integer that is a JSON number and not a boolean (`bool is not int`, PROTOCOL §8).
	static func strictInt(_ value: Any?) -> Int? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
			!CFNumberIsFloatType(number)
		else { return nil }
		return number.intValue
	}

	/// Python's `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)` for a
	/// flat object of strings and integers — the §7.1 canonical form. Nil for any other value.
	static func pythonCanonical(_ object: [String: Any]) -> Data? {
		var out = "{"
		for (index, key) in object.keys.sorted(by: {
			Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value))
		}).enumerated() {
			if index > 0 { out += "," }
			out += pythonString(key) + ":"
			let value = object[key]
			if let text = value as? String {
				out += pythonString(text)
			} else if let number = strictInt(value) {
				out += String(number)
			} else {
				return nil
			}
		}
		out += "}"
		return Data(out.utf8)
	}

	private static func pythonString(_ text: String) -> String {
		var out = "\""
		for unit in text.utf16 {
			switch unit {
			case 0x22: out += "\\\""
			case 0x5C: out += "\\\\"
			case 0x0A: out += "\\n"
			case 0x0D: out += "\\r"
			case 0x09: out += "\\t"
			case 0x08: out += "\\b"
			case 0x0C: out += "\\f"
			case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(unit)!)
			default: out += String(format: "\\u%04x", unit)
			}
		}
		return out + "\""
	}
}
