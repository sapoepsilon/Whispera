import Foundation

/// Every PROTOCOL §13 error code plus the backend-specific ones, with its HTTP
/// status. Rust: `whispera_proto::error::ErrorCode` — same 32 cases, same order, same
/// wire strings, same statuses.
public enum ErrorCode: String, CaseIterable, Codable, Sendable, Error {
	case badRequest = "bad_request"
	case authMissing = "auth_missing"
	case authUnknownDevice = "auth_unknown_device"
	case authRevoked = "auth_revoked"
	case authClockSkew = "auth_clock_skew"
	case authBadSignature = "auth_bad_signature"
	case authReplay = "auth_replay"
	case pairCodeInvalid = "pair_code_invalid"
	case notFound = "not_found"
	case agentBlocked = "agent_blocked"
	case approvalNotPending = "approval_not_pending"
	case pairCodeExpired = "pair_code_expired"
	case approvalExpired = "approval_expired"
	case lengthRequired = "length_required"
	case payloadTooLarge = "payload_too_large"
	case badSignature = "bad_signature"
	case pairLocked = "pair_locked"
	case rateLimited = "rate_limited"
	case `internal` = "internal"
	case herdrError = "herdr_error"
	case upstreamError = "upstream_error"
	case herdrUnavailable = "herdr_unavailable"
	case brokerUnavailable = "broker_unavailable"
	case upstreamUnconfigured = "upstream_unconfigured"
	case herdrTimeout = "herdr_timeout"
	case brokerTimeout = "broker_timeout"
	case upstreamTimeout = "upstream_timeout"
	// backend-specific
	case authAccountMissing = "auth_account_missing"
	case authAccountInvalid = "auth_account_invalid"
	case authUnavailable = "auth_unavailable"
	case forbidden = "forbidden"
	case mailboxFull = "mailbox_full"

	public var httpStatus: Int {
		switch self {
		case .badRequest: return 400
		case .authMissing, .authUnknownDevice, .authRevoked, .authClockSkew, .authBadSignature, .authReplay,
		     .authAccountMissing, .authAccountInvalid:
			return 401
		case .pairCodeInvalid, .forbidden: return 403
		case .notFound: return 404
		case .agentBlocked, .approvalNotPending: return 409
		case .pairCodeExpired, .approvalExpired: return 410
		case .lengthRequired: return 411
		case .payloadTooLarge: return 413
		case .badSignature: return 422
		case .pairLocked, .rateLimited, .mailboxFull: return 429
		case .internal: return 500
		case .herdrError, .upstreamError: return 502
		case .herdrUnavailable, .brokerUnavailable, .upstreamUnconfigured, .authUnavailable: return 503
		case .herdrTimeout, .brokerTimeout, .upstreamTimeout: return 504
		}
	}

	/// §13 `type`, mapped from the HTTP status.
	public var errorType: String { Self.errorType(forStatus: httpStatus) }

	/// §13 mapping of HTTP status to error `type` (`error_type_for_status`).
	public static func errorType(forStatus status: Int) -> String {
		switch status {
		case 401, 403, 429: return "auth_error"
		case 400, 411, 413, 422: return "invalid_request_error"
		case 404: return "not_found_error"
		case 409, 410: return "conflict_error"
		case 502...504: return "upstream_error"
		default: return "server_error"
		}
	}
}

/// `{"error": {...}}`, the OpenAI-compatible error envelope. Rust: `ErrorEnvelope`.
public struct ErrorEnvelope: Codable, Equatable, Sendable {
	public var error: ErrorBody

	public init(error: ErrorBody) {
		self.error = error
	}

	public init(_ code: ErrorCode, message: String, serverTime: Int64? = nil) {
		error = ErrorBody(code: code.rawValue, message: message, type: code.errorType, serverTime: serverTime)
	}

	public var httpStatus: Int { ErrorCode(rawValue: error.code)?.httpStatus ?? 500 }

	/// Compact JSON with sorted keys, the form a server sends.
	public func encoded() -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return (try? encoder.encode(self)) ?? Data()
	}
}

/// The error object. `code` stays a `String` so a client can still read codes newer
/// than itself; `errorCode` gives the typed view when it is a known one. Extra fields
/// such as `herdr_code` or `status` are kept in `extra`, as Rust flattens them.
public struct ErrorBody: Codable, Equatable, Sendable {
	public var code: String
	public var message: String
	public var type: String
	public var serverTime: Int64?
	public var extra: [String: JSONScalar]

	public init(code: String, message: String, type: String, serverTime: Int64? = nil, extra: [String: JSONScalar] = [:]) {
		self.code = code
		self.message = message
		self.type = type
		self.serverTime = serverTime
		self.extra = extra
	}

	public var errorCode: ErrorCode? { ErrorCode(rawValue: code) }

	private struct Key: CodingKey {
		var stringValue: String
		var intValue: Int? { nil }
		init(_ string: String) { stringValue = string }
		init?(stringValue: String) { self.stringValue = stringValue }
		init?(intValue: Int) { nil }
	}

	private static let known: Set<String> = ["code", "message", "type", "server_time"]

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		code = try container.decodeIfPresent(String.self, forKey: Key("code")) ?? ""
		message = try container.decodeIfPresent(String.self, forKey: Key("message")) ?? ""
		type = try container.decodeIfPresent(String.self, forKey: Key("type")) ?? ""
		serverTime = try container.decodeIfPresent(Int64.self, forKey: Key("server_time"))
		var extra: [String: JSONScalar] = [:]
		for key in container.allKeys where !Self.known.contains(key.stringValue) {
			if let value = try? container.decode(JSONScalar.self, forKey: key) { extra[key.stringValue] = value }
		}
		self.extra = extra
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		try container.encode(code, forKey: Key("code"))
		try container.encode(message, forKey: Key("message"))
		try container.encode(type, forKey: Key("type"))
		try container.encodeIfPresent(serverTime, forKey: Key("server_time"))
		for (name, value) in extra where !Self.known.contains(name) {
			try container.encode(value, forKey: Key(name))
		}
	}
}

/// A JSON scalar, enough for the flattened extras of an error body.
public enum JSONScalar: Codable, Equatable, Sendable {
	case string(String)
	case int(Int64)
	case double(Double)
	case bool(Bool)
	case null

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Int64.self) {
			self = .int(value)
		} else if let value = try? container.decode(Double.self) {
			self = .double(value)
		} else {
			self = .string(try container.decode(String.self))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .string(let value): try container.encode(value)
		case .int(let value): try container.encode(value)
		case .double(let value): try container.encode(value)
		case .bool(let value): try container.encode(value)
		case .null: try container.encodeNil()
		}
	}

	public var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}
}

/// What a client throws for any failed call: a decoded error envelope, a transport
/// failure (`status == 0`), or a response it could not read.
public struct LinkError: LocalizedError, Equatable, Sendable {
	public var code: String
	public var message: String
	public var status: Int
	public var type: String?
	public var serverTime: Int?
	public var herdrCode: String?

	public init(code: String, message: String, status: Int, type: String? = nil, serverTime: Int? = nil, herdrCode: String? = nil) {
		self.code = code
		self.message = message
		self.status = status
		self.type = type
		self.serverTime = serverTime
		self.herdrCode = herdrCode
	}

	public var errorDescription: String? { message }

	/// The typed code when the server sent a known one.
	public var errorCode: ErrorCode? { ErrorCode(rawValue: code) }

	public static func timedOut(_ what: String) -> LinkError {
		LinkError(code: "timed_out", message: "\(what) timed out", status: 0)
	}

	public static func transport(_ error: Error) -> LinkError {
		LinkError(code: "unreachable", message: "Couldn't reach your Mac: \(error.localizedDescription)", status: 0)
	}

	public static func badResponse(_ detail: String, status: Int = 200) -> LinkError {
		LinkError(code: "bad_response", message: detail, status: status)
	}

	/// Reads an error envelope out of a non-2xx response; falls back to `http_<status>`.
	public static func decode(status: Int, body: Data) -> LinkError {
		if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
			return LinkError(
				code: envelope.error.code.isEmpty ? "http_\(status)" : envelope.error.code,
				message: envelope.error.message.isEmpty ? "HTTP \(status)" : envelope.error.message,
				status: status,
				type: envelope.error.type.isEmpty ? nil : envelope.error.type,
				serverTime: envelope.error.serverTime.map { Int($0) },
				herdrCode: envelope.error.extra["herdr_code"]?.stringValue)
		}
		let text = String(data: body.prefix(300), encoding: .utf8) ?? ""
		return LinkError(code: "http_\(status)", message: "HTTP \(status)\(text.isEmpty ? "" : ": \(text)")", status: status)
	}
}
