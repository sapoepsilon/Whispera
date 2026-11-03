import Foundation

/// One dispatched `text/event-stream` event.
public struct SSEEvent: Sendable, Equatable {
	public let event: String?
	public let id: String?
	/// Multiple `data:` lines in one event are joined with a newline, per the
	/// spec — which matters because a JSON payload split across lines would
	/// otherwise be unparseable.
	public let data: String

	public init(event: String? = nil, id: String? = nil, data: String) {
		self.event = event
		self.id = id
		self.data = data
	}
}

/// An incremental `text/event-stream` parser.
///
/// Incremental because the bytes arrive in whatever chunks the network hands
/// over, and a chunk boundary lands mid-line often enough that "split the body
/// on newlines" is a bug waiting for a slow server. Feeding it one byte at a
/// time and feeding it the whole body at once must produce the same events, and
/// that is exactly what the chunked fixtures pin.
public struct SSEParser: Sendable {
	private var pending = Data()
	private var dataLines: [String] = []
	private var event: String?
	private var id: String?
	/// A lone `\r` at the end of a chunk may be the first half of a `\r\n`, so it
	/// cannot be treated as a line ending until the next chunk says otherwise.
	private var sawCarriageReturn = false

	public init() {}

	public mutating func consume(_ chunk: Data) -> [SSEEvent] {
		var events: [SSEEvent] = []
		for byte in chunk {
			if let dispatched = consume(byte) { events.append(dispatched) }
		}
		return events
	}

	/// One byte at a time, which is the granularity `URLSession.AsyncBytes`
	/// offers.
	///
	/// Note what is deliberately *not* used to drive this: `AsyncBytes.lines`.
	/// That sequence collapses consecutive newlines, so the blank line that ends
	/// an SSE event never arrives and nothing is ever dispatched — a stream read
	/// through it looks like a server that sent no tokens at all.
	public mutating func consume(_ byte: UInt8) -> SSEEvent? {
		if sawCarriageReturn {
			sawCarriageReturn = false
			if byte == 0x0A { return endLine() }
			let dispatched = endLine()
			let next = append(byte)
			return dispatched ?? next
		}
		return append(byte)
	}

	private mutating func append(_ byte: UInt8) -> SSEEvent? {
		switch byte {
		case 0x0D:
			sawCarriageReturn = true
			return nil
		case 0x0A:
			return endLine()
		default:
			pending.append(byte)
			return nil
		}
	}

	/// Flushes whatever a stream that ended without a trailing blank line left
	/// behind. A server closing the socket right after the last `data:` line is
	/// common enough that dropping it would lose real tokens.
	public mutating func finish() -> [SSEEvent] {
		var events: [SSEEvent] = []
		if sawCarriageReturn {
			sawCarriageReturn = false
			if let dispatched = endLine() { events.append(dispatched) }
		}
		if !pending.isEmpty, let dispatched = endLine() { events.append(dispatched) }
		if let dispatched = dispatch() { events.append(dispatched) }
		return events
	}

	private mutating func endLine() -> SSEEvent? {
		let line = String(decoding: pending, as: UTF8.self)
		pending.removeAll(keepingCapacity: true)
		process(line: line)
		return line.isEmpty ? dispatch() : nil
	}

	private mutating func process(line: String) {
		guard !line.isEmpty else { return }
		// A line opening with a colon is a comment — the keep-alive heartbeat
		// proxies send to stop an idle stream being closed under them.
		guard !line.hasPrefix(":") else { return }

		let field: String
		var value: String
		if let separator = line.firstIndex(of: ":") {
			field = String(line[line.startIndex..<separator])
			value = String(line[line.index(after: separator)...])
			if value.hasPrefix(" ") { value.removeFirst() }
		} else {
			field = line
			value = ""
		}

		switch field {
		case "data": dataLines.append(value)
		case "event": event = value
		case "id": id = value
		default: break
		}
	}

	private mutating func dispatch() -> SSEEvent? {
		defer {
			dataLines.removeAll(keepingCapacity: true)
			event = nil
			id = nil
		}
		guard !dataLines.isEmpty else { return nil }
		return SSEEvent(event: event, id: id, data: dataLines.joined(separator: "\n"))
	}
}
