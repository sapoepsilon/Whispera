import Foundation

/// The phone's terminal wire frames (one WebSocket binary message each; over SSE the base64 of
/// the same bytes). Integers are big-endian.
enum TerminalFrame {
	static let hello: UInt8 = 0x01
	static let output: UInt8 = 0x02
	static let reset: UInt8 = 0x03
	static let size: UInt8 = 0x04
	static let ack: UInt8 = 0x05
	static let exit: UInt8 = 0x06
	/// Where the phone's swipes go: `{"app": true}` while the pane has no scrollback (a
	/// full-screen app; the helper takes `scroll` frames for it), false when the phone's own
	/// history view should scroll. Phones that predate it drop the unknown frame.
	static let scrollState: UInt8 = 0x07

	static let input: UInt8 = 0x10
	static let resize: UInt8 = 0x11
	static let mode: UInt8 = 0x12
	static let scroll: UInt8 = 0x13
	/// Wheel notches one `scroll` frame may carry, either way.
	static let maxScrollNotches = 20

	static let maxInputBytes = 16 * 1024
	static let sizeRange: ClosedRange<Int> = 2...500

	private static func json(_ type: UInt8, _ object: [String: Any]) -> Data {
		var out = Data([type])
		out.append(WireJSON.encode(object))
		return out
	}

	static func encodeHello(
		session: String, size: TerminalSize, mode: TerminalMode, provider: String, resumed: Bool, idleTimeout: Int,
		scroll: Bool = false, appScroll: Bool? = nil, readOnly: Bool = false
	) -> Data {
		var object: [String: Any] = [
			"session": session, "cols": size.cols, "rows": size.rows, "mode": mode.rawValue, "provider": provider,
			"resumed": resumed, "idle_timeout": idleTimeout, "scroll": scroll,
		]
		if let appScroll { object["app_scroll"] = appScroll }
		// A view-only mirror (herdr-core): input is dropped and fit stays a mirror.
		if readOnly { object["read_only"] = true }
		return json(hello, object)
	}

	static func encodeScrollState(app: Bool) -> Data { json(scrollState, ["app": app]) }

	static func encodeOutput(seq: UInt64, _ bytes: Data) -> Data {
		var out = Data([output])
		for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((seq >> UInt64(shift)) & 0xFF)) }
		out.append(bytes)
		return out
	}

	static func encodeReset(_ size: TerminalSize) -> Data { json(reset, ["cols": size.cols, "rows": size.rows]) }
	static func encodeSize(_ size: TerminalSize) -> Data { json(self.size, ["cols": size.cols, "rows": size.rows]) }

	static func encodeAck(_ seq: UInt32) -> Data {
		Data([ack, UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)])
	}

	static func encodeExit(_ reason: TerminalExit) -> Data { json(exit, ["reason": reason.rawValue]) }

	/// Phone → Mac.
	enum Client: Equatable {
		case input(seq: UInt32, Data)
		case resize(TerminalSize)
		case mode(TerminalMode)
		/// Wheel notches for a full-screen app in the pane, positive up (earlier output).
		case scroll(Int)
	}

	static func encodeClient(_ frame: Client) -> Data {
		switch frame {
		case .input(let seq, let bytes):
			var out = Data([input, UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)])
			out.append(bytes)
			return out
		case .resize(let size):
			return Data([
				resize, UInt8(size.cols >> 8), UInt8(size.cols & 0xFF), UInt8(size.rows >> 8), UInt8(size.rows & 0xFF),
			])
		case .mode(let mode): return json(self.mode, ["mode": mode.rawValue])
		case .scroll(let notches):
			let value = UInt16(bitPattern: Int16(max(-maxScrollNotches, min(maxScrollNotches, notches))))
			return Data([scroll, UInt8(value >> 8), UInt8(value & 0xFF)])
		}
	}

	/// Frames carry no per-frame authentication: only the WebSocket upgrade is signed, and every
	/// frame after it is trusted as the device that signed it. That holds because the connection
	/// itself is protected, either by the tailnet (WireGuard) or loopback (`DirectAccessPolicy`),
	/// or by the sealed relay; a token echoed in each frame would add nothing against someone who
	/// can read and rewrite the stream. That is why the WebSocket is refused to plain local network
	/// peers even with plain-LAN access on (`LinkAPI.terminalWebSocket`); they use SSE plus signed
	/// POST input.
	static func decodeClient(_ data: Data) throws -> Client {
		let bytes = [UInt8](data)
		guard let type = bytes.first else { throw APIError(400, "bad_request", "empty terminal frame") }
		switch type {
		case input:
			guard bytes.count >= 6, bytes.count - 5 <= maxInputBytes else {
				throw APIError(400, "bad_request", "input must carry 1-16384 bytes")
			}
			let seq = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
			return .input(seq: seq, Data(bytes[5...]))
		case resize:
			guard bytes.count == 5 else { throw APIError(400, "bad_request", "resize is 4 bytes") }
			let cols = Int(bytes[1]) << 8 | Int(bytes[2])
			let rows = Int(bytes[3]) << 8 | Int(bytes[4])
			guard sizeRange.contains(cols), sizeRange.contains(rows) else {
				throw APIError(400, "bad_request", "cols and rows must be 2-500")
			}
			return .resize(TerminalSize(cols: cols, rows: rows))
		case mode:
			guard let object = WireJSON.decodeObject(Data(bytes[1...])), let raw = object["mode"] as? String,
				let mode = TerminalMode(rawValue: raw)
			else { throw APIError(400, "bad_request", "mode must be mirror or fit") }
			return .mode(mode)
		case scroll:
			guard bytes.count == 3 else { throw APIError(400, "bad_request", "scroll is 2 bytes") }
			let notches = Int(Int16(bitPattern: UInt16(bytes[1]) << 8 | UInt16(bytes[2])))
			guard notches != 0, abs(notches) <= maxScrollNotches else {
				throw APIError(400, "bad_request", "scroll must be 1-\(maxScrollNotches) notches either way")
			}
			return .scroll(notches)
		default:
			throw APIError(400, "bad_request", "unknown terminal frame")
		}
	}
}

struct TerminalSize: Equatable, Sendable, CustomStringConvertible {
	var cols: Int
	var rows: Int
	var description: String { "\(cols)x\(rows)" }
}

enum TerminalMode: String, Sendable {
	case mirror, fit
}

enum TerminalExit: String, Sendable {
	case ended, idle, replaced, revoked
	case rateLimited = "rate_limited"
}

/// The last frames a session sent, for a reconnect with `after=N`. Output frames carry their
/// seq; reset/size frames are kept at the seq of the output they followed, so a replay after N
/// includes the controls sent after output N and every output from N+1 on.
struct TerminalRing {
	struct Entry {
		var position: UInt64
		var isOutput: Bool
		var frame: Data
	}

	let maxFrames: Int
	let maxBytes: Int
	private(set) var entries: [Entry] = []
	private(set) var bytes = 0
	private(set) var lastSeq: UInt64 = 0
	private var lastEvicted: (position: UInt64, isOutput: Bool)?

	init(maxFrames: Int = 512, maxBytes: Int = 2 << 20) {
		self.maxFrames = maxFrames
		self.maxBytes = maxBytes
	}

	/// Records an output frame (`seq` must be `lastSeq + 1`) or a control frame.
	mutating func append(_ frame: Data, outputSeq seq: UInt64?) {
		if let seq { lastSeq = seq }
		entries.append(Entry(position: lastSeq, isOutput: seq != nil, frame: frame))
		bytes += frame.count
		var drop = 0
		while entries.count - drop > maxFrames || (bytes > maxBytes && entries.count - drop > 1) {
			let gone = entries[drop]
			bytes -= gone.frame.count
			lastEvicted = (gone.position, gone.isOutput)
			drop += 1
		}
		if drop > 0 { entries.removeFirst(drop) }
	}

	/// Exactly the frames sent after output `after`, or nil when some of them are gone (or
	/// `after` is in the future).
	func frames(after: UInt64) -> [Entry]? {
		guard after <= lastSeq else { return nil }
		if let evicted = lastEvicted {
			if evicted.isOutput ? evicted.position > after : evicted.position >= after { return nil }
		}
		return entries.filter { $0.isOutput ? $0.position > after : $0.position >= after }
	}
}

/// Token buckets for one session's input: frames per second and bytes per second, each with a
/// one-second burst. Sustained abuse (many drops within `abuseWindow`) ends the session.
struct TerminalInputLimiter {
	enum Verdict: Equatable { case accept, drop, abuse }

	let framesPerSecond: Double
	let bytesPerSecond: Double
	let abuseDrops: Int
	let abuseWindow: Double
	private var frameTokens: Double
	private var byteTokens: Double
	private var last: Double
	private var drops: [Double] = []

	init(
		framesPerSecond: Double = 300, bytesPerSecond: Double = 256 * 1024, abuseDrops: Int = 300,
		abuseWindow: Double = 10, now: Double
	) {
		self.framesPerSecond = framesPerSecond
		self.bytesPerSecond = bytesPerSecond
		self.abuseDrops = abuseDrops
		self.abuseWindow = abuseWindow
		frameTokens = framesPerSecond
		byteTokens = bytesPerSecond
		last = now
	}

	mutating func admit(bytes: Int, now: Double) -> Verdict {
		let elapsed = max(0, now - last)
		last = now
		frameTokens = min(framesPerSecond, frameTokens + elapsed * framesPerSecond)
		byteTokens = min(bytesPerSecond, byteTokens + elapsed * bytesPerSecond)
		if frameTokens >= 1, byteTokens >= Double(bytes) {
			frameTokens -= 1
			byteTokens -= Double(bytes)
			return .accept
		}
		drops = drops.filter { now - $0 <= abuseWindow }
		drops.append(now)
		return drops.count >= abuseDrops ? .abuse : .drop
	}
}

/// At most `limit` terminal opens per device per `window` seconds.
struct TerminalOpenLimiter {
	let limit: Int
	let window: Double
	private var opens: [String: [Double]] = [:]

	init(limit: Int = 20, window: Double = 60) {
		self.limit = limit
		self.window = window
	}

	mutating func admit(_ deviceID: String, now: Double) -> Bool {
		var recent = (opens[deviceID] ?? []).filter { now - $0 < window }
		guard recent.count < limit else {
			opens[deviceID] = recent
			return false
		}
		recent.append(now)
		opens[deviceID] = recent
		return true
	}
}
