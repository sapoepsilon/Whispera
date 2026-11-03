import Foundation

public struct SSEFrame: Equatable, Sendable {
	public var id: String?
	public var event: String
	public var data: String

	public init(id: String? = nil, event: String, data: String) {
		self.id = id
		self.event = event
		self.data = data
	}
}

/// Incremental `text/event-stream` parser: feed bytes, get frames. Comment lines
/// (`: ping`) produce nothing but still count as liveness for the caller.
public struct LinkSSEParser: Sendable {
	public init() {}

	private var line = Data()
	private var event: String?
	private var dataLines: [String] = []
	private var id: String?
	private var lastByteWasCR = false

	public mutating func consume(_ byte: UInt8) -> SSEFrame? {
		if byte == UInt8(ascii: "\n") && lastByteWasCR {
			lastByteWasCR = false
			return nil
		}
		lastByteWasCR = byte == UInt8(ascii: "\r")
		if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
			let text = String(decoding: line, as: UTF8.self)
			line.removeAll(keepingCapacity: true)
			return processLine(text)
		}
		line.append(byte)
		return nil
	}

	public mutating func consume(_ chunk: String) -> [SSEFrame] {
		chunk.utf8.compactMap { consume($0) }
	}

	private mutating func processLine(_ text: String) -> SSEFrame? {
		if text.isEmpty {
			defer {
				event = nil
				dataLines = []
			}
			guard !dataLines.isEmpty || event != nil else { return nil }
			return SSEFrame(id: id, event: event ?? "message", data: dataLines.joined(separator: "\n"))
		}
		if text.hasPrefix(":") { return nil }
		let field: Substring
		var value: Substring
		if let colon = text.firstIndex(of: ":") {
			field = text[..<colon]
			value = text[text.index(after: colon)...]
			if value.hasPrefix(" ") { value = value.dropFirst() }
		} else {
			field = Substring(text)
			value = ""
		}
		switch field {
		case "event": event = String(value)
		case "data": dataLines.append(String(value))
		case "id": id = String(value)
		default: break
		}
		return nil
	}

	public static func event(from frame: SSEFrame) -> LinkEvent? {
		let object = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any] ?? [:]
		switch frame.event {
		case "hello":
			return .hello(lastSeq: object["last_seq"] as? Int, serverTime: object["server_time"] as? Int)
		case "agent.status":
			guard let id = object["id"] as? String else { return nil }
			return .agentStatus(id: id, status: object["status"] as? String ?? "unknown")
		case "agents.changed":
			return .agentsChanged
		case "approval.pending":
			guard let id = object["request_id"] as? String else { return nil }
			return .approvalPending(requestID: id, expiresAt: object["expires_at"] as? Int)
		case "approval.resolved":
			guard let id = object["request_id"] as? String else { return nil }
			return .approvalResolved(requestID: id, status: object["status"] as? String ?? "unknown")
		case "herdr.down":
			return .herdrDown
		case "herdr.up":
			return .herdrUp
		case "resync":
			return .resync
		default:
			return nil
		}
	}
}
