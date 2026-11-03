import CryptoKit
import Foundation

/// RFC 6455 for the terminal route: the handshake key, frame encode/decode and message
/// reassembly as pure functions (unit-tested), plus a blocking connection over an upgraded
/// `HTTPExchange`. Only what a phone client needs: no extensions, no subprotocols.
enum WebSocket {
	static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	static let maxMessageBytes = 1 << 20

	enum Opcode: UInt8 {
		case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA

		var isControl: Bool { rawValue & 0x8 != 0 }
	}

	struct Frame: Equatable {
		var fin: Bool
		var opcode: Opcode
		var payload: Data
	}

	enum Message: Equatable {
		case text(Data)
		case binary(Data)
		case ping(Data)
		case pong(Data)
		case close(code: UInt16?, reason: Data)
	}

	enum Failure: Error, Equatable {
		/// 1002: a malformed frame or a broken fragment sequence.
		case protocolError(String)
		/// 1009: a frame or message over the limit.
		case tooBig
	}

	/// `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key`.
	static func acceptKey(_ key: String) -> String {
		Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
	}

	/// A key is 16 random bytes in base64 (RFC 6455 §4.1).
	static func isValidKey(_ key: String) -> Bool {
		Data(base64Encoded: key)?.count == 16
	}

	/// One frame. Server frames go unmasked (`mask` nil); a client passes its 4-byte key.
	static func encode(_ opcode: Opcode, _ payload: Data, fin: Bool = true, mask: [UInt8]? = nil) -> Data {
		var out = Data()
		out.append((fin ? 0x80 : 0) | opcode.rawValue)
		let maskBit: UInt8 = mask == nil ? 0 : 0x80
		let count = payload.count
		if count < 126 {
			out.append(maskBit | UInt8(count))
		} else if count <= 0xFFFF {
			out.append(maskBit | 126)
			out.append(UInt8(count >> 8))
			out.append(UInt8(count & 0xFF))
		} else {
			out.append(maskBit | 127)
			for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
		}
		if let mask {
			out.append(contentsOf: mask)
			var masked = [UInt8](payload)
			for index in masked.indices { masked[index] ^= mask[index & 3] }
			out.append(contentsOf: masked)
		} else {
			out.append(payload)
		}
		return out
	}

	static func closePayload(_ code: UInt16, _ reason: String = "") -> Data {
		var out = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
		out.append(Data(reason.utf8.prefix(120)))
		return out
	}

	/// The first complete frame in `buffer` and the bytes it used, or nil when more is needed.
	/// A server requires masked frames (`requireMask`) and refuses payloads over `maxPayload`.
	static func decodeFrame(_ buffer: Data, requireMask: Bool, maxPayload: Int = maxMessageBytes) throws -> (
		Frame, Int
	)? {
		let bytes = [UInt8](buffer.prefix(14))
		guard bytes.count >= 2 else { return nil }
		let first = bytes[0]
		let second = bytes[1]
		guard first & 0x70 == 0 else { throw Failure.protocolError("reserved bits set") }
		guard let opcode = Opcode(rawValue: first & 0x0F) else { throw Failure.protocolError("unknown opcode") }
		let fin = first & 0x80 != 0
		let masked = second & 0x80 != 0
		if requireMask, !masked { throw Failure.protocolError("client frames must be masked") }
		var length = UInt64(second & 0x7F)
		var offset = 2
		if length == 126 {
			guard bytes.count >= 4 else { return nil }
			length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
			offset = 4
		} else if length == 127 {
			guard bytes.count >= 10 else { return nil }
			length = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
			guard length & (1 << 63) == 0 else { throw Failure.protocolError("bad length") }
			offset = 10
		}
		if opcode.isControl {
			guard fin else { throw Failure.protocolError("fragmented control frame") }
			guard length <= 125 else { throw Failure.protocolError("control frame over 125 bytes") }
		}
		guard length <= UInt64(maxPayload) else { throw Failure.tooBig }
		var key: [UInt8] = []
		if masked {
			guard bytes.count >= offset + 4 else { return nil }
			key = Array(bytes[offset..<offset + 4])
			offset += 4
		}
		let total = offset + Int(length)
		guard buffer.count >= total else { return nil }
		let start = buffer.startIndex + offset
		var payload = [UInt8](buffer[start..<start + Int(length)])
		if masked { for index in payload.indices { payload[index] ^= key[index & 3] } }
		return (Frame(fin: fin, opcode: opcode, payload: Data(payload)), total)
	}

	/// Joins fragments into messages; control frames pass straight through (they may arrive
	/// between the fragments of a data message).
	struct Assembler {
		let maxMessage: Int
		private var opcode: Opcode?
		private var parts = Data()

		init(maxMessage: Int = WebSocket.maxMessageBytes) { self.maxMessage = maxMessage }

		mutating func push(_ frame: Frame) throws -> Message? {
			switch frame.opcode {
			case .ping: return .ping(frame.payload)
			case .pong: return .pong(frame.payload)
			case .close:
				let payload = frame.payload
				guard payload.count != 1 else { throw Failure.protocolError("1-byte close payload") }
				let bytes = [UInt8](payload)
				let code = bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil
				return .close(code: code, reason: payload.count > 2 ? payload.dropFirst(2) : Data())
			case .text, .binary:
				guard opcode == nil else { throw Failure.protocolError("new message inside a fragmented one") }
				guard frame.payload.count <= maxMessage else { throw Failure.tooBig }
				if frame.fin { return frame.opcode == .text ? .text(frame.payload) : .binary(frame.payload) }
				opcode = frame.opcode
				parts = frame.payload
				return nil
			case .continuation:
				guard let started = opcode else { throw Failure.protocolError("continuation without a message") }
				guard parts.count + frame.payload.count <= maxMessage else { throw Failure.tooBig }
				parts.append(frame.payload)
				guard frame.fin else { return nil }
				let message = parts
				opcode = nil
				parts = Data()
				return started == .text ? .text(message) : .binary(message)
			}
		}
	}

	/// What a handshake request must carry; the reason when it does not.
	static func handshakeProblem(_ header: (String) -> String?) -> String? {
		guard header("Upgrade")?.lowercased() == "websocket" else { return "Upgrade: websocket is required" }
		let tokens = (header("Connection") ?? "").lowercased().split(separator: ",").map {
			$0.trimmingCharacters(in: .whitespaces)
		}
		guard tokens.contains("upgrade") else { return "Connection: Upgrade is required" }
		guard header("Sec-WebSocket-Version") == "13" else { return "Sec-WebSocket-Version must be 13" }
		guard let key = header("Sec-WebSocket-Key"), isValidKey(key) else { return "bad Sec-WebSocket-Key" }
		return nil
	}
}

/// A server-side WebSocket over an upgraded connection. `send` is safe from any thread;
/// `receive` is called from one reader thread only.
final class WebSocketConnection: @unchecked Sendable {
	private let exchange: HTTPExchange
	private var buffer: Data
	private var assembler = WebSocket.Assembler()
	private let sendLock = NSLock()
	private let stateLock = NSLock()
	private var closed = false
	private var lastHeard = Date()

	init(exchange: HTTPExchange, leftover: Data) {
		self.exchange = exchange
		buffer = leftover
	}

	var isOpen: Bool {
		stateLock.lock()
		defer { stateLock.unlock() }
		return !closed && exchange.isAlive
	}

	/// Seconds since the peer last sent anything (pongs included).
	var silence: TimeInterval {
		stateLock.lock()
		defer { stateLock.unlock() }
		return -lastHeard.timeIntervalSinceNow
	}

	func send(_ opcode: WebSocket.Opcode, _ payload: Data) throws {
		sendLock.lock()
		defer { sendLock.unlock() }
		try exchange.write(WebSocket.encode(opcode, payload), timeout: 30)
	}

	func sendBinary(_ payload: Data) throws { try send(.binary, payload) }

	/// Several binary messages in one write (one TCP send for a batch of terminal frames).
	func sendBinary(batch payloads: [Data]) throws {
		guard payloads.count > 1 else {
			if let only = payloads.first { try sendBinary(only) }
			return
		}
		var out = Data()
		for payload in payloads { out.append(WebSocket.encode(.binary, payload)) }
		sendLock.lock()
		defer { sendLock.unlock() }
		try exchange.write(out, timeout: 30)
	}

	/// Sends a close frame (once) and drops the connection.
	func close(_ code: UInt16 = 1000, _ reason: String = "") {
		stateLock.lock()
		let already = closed
		closed = true
		stateLock.unlock()
		if !already { try? send(.close, WebSocket.closePayload(code, reason)) }
		exchange.close()
	}

	/// The next data or control message; throws when the connection is gone or broken (after
	/// closing it with the matching status). Pings are answered here.
	func receive() throws -> WebSocket.Message {
		while true {
			do {
				while let (frame, used) = try WebSocket.decodeFrame(buffer, requireMask: true) {
					buffer.removeFirst(used)
					guard let message = try assembler.push(frame) else { continue }
					switch message {
					case .ping(let payload): try? send(.pong, payload)
					case .close:
						close(1000)
					default: break
					}
					return message
				}
			} catch WebSocket.Failure.tooBig {
				close(1009, "message too big")
				throw HTTPExchange.ConnectionGone()
			} catch is WebSocket.Failure {
				close(1002, "protocol error")
				throw HTTPExchange.ConnectionGone()
			}
			// No timeout of its own: an abandoned receive would swallow the next chunk.
			// `close` cancels the connection, which ends this wait.
			let chunk = try HTTPExchange.receive(exchange.connection, timeout: 24 * 3600)
			stateLock.lock()
			lastHeard = Date()
			stateLock.unlock()
			buffer.append(chunk)
		}
	}
}
