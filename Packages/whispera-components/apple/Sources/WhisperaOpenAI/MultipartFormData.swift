import Foundation

/// One `multipart/form-data` encoder for the whole package.
///
/// There used to be two of these — one per upload call site — which is one more
/// than a wire format needs. The boundary is injectable so the encoding can be
/// pinned by golden bytes rather than by "does it contain the word file".
public struct MultipartFormData: Sendable {
	private enum Part: Sendable {
		case field(name: String, value: String)
		case file(name: String, filename: String, mimetype: String, data: Data)
	}

	public let boundary: String
	private var parts: [Part] = []

	public init(boundary: String = "whispera.\(UUID().uuidString)") {
		self.boundary = boundary
	}

	public mutating func addField(name: String, value: String) {
		parts.append(.field(name: name, value: value))
	}

	/// Adds every field in key order, so a body built from a dictionary is
	/// byte-identical run to run — a dictionary's own order is not.
	public mutating func addFields(_ fields: [String: String]) {
		for name in fields.keys.sorted() {
			addField(name: name, value: fields[name]!)
		}
	}

	public mutating func addFile(
		name: String, filename: String, mimetype: String, data: Data
	) {
		parts.append(.file(name: name, filename: filename, mimetype: mimetype, data: data))
	}

	public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

	public func encoded() -> Data {
		let crlf = "\r\n"
		var body = Data()

		func append(_ text: String) { body.append(Data(text.utf8)) }

		for part in parts {
			append("--\(boundary)\(crlf)")
			switch part {
			case .field(let name, let value):
				append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
				append("\(value)\(crlf)")
			case .file(let name, let filename, let mimetype, let data):
				append(
					"Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\(crlf)")
				append("Content-Type: \(mimetype)\(crlf)\(crlf)")
				body.append(data)
				append(crlf)
			}
		}
		append("--\(boundary)--\(crlf)")
		return body
	}
}
