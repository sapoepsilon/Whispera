import Foundation

/// A coded failure that becomes the §13 error envelope on HTTP and the error object on the
/// admin socket. Every module throws this one type so the routes never translate errors.
public struct APIError: Error, @unchecked Sendable {
	public var status: Int
	public var code: String
	public var message: String
	public var extra: [String: Any]

	public init(_ status: Int, _ code: String, _ message: String, extra: [String: Any] = [:]) {
		self.status = status
		self.code = code
		self.message = message
		self.extra = extra
	}

	static let errorTypes: [Int: String] = [
		400: "invalid_request_error", 401: "auth_error", 403: "auth_error", 404: "not_found_error",
		409: "conflict_error", 410: "conflict_error", 411: "invalid_request_error", 413: "invalid_request_error",
		422: "invalid_request_error", 429: "auth_error", 500: "server_error", 502: "upstream_error",
		503: "upstream_error", 504: "upstream_error",
	]

	/// `{"error":{"code","message","type",…extras}}` (§13).
	public var envelope: Data {
		var body: [String: Any] = [
			"code": code, "message": message, "type": Self.errorTypes[status] ?? "server_error",
		]
		for (key, value) in extra where body[key] == nil { body[key] = value }
		return WireJSON.encode(["error": body])
	}

	/// The admin socket's `{"ok":false,"error":{…}}` (§3.1).
	var adminObject: [String: Any] {
		var body: [String: Any] = ["code": code, "message": message, "http_status": status]
		for (key, value) in extra where body[key] == nil { body[key] = value }
		return ["ok": false, "error": body]
	}
}
