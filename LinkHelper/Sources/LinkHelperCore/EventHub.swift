import Foundation

/// In-process pub/sub with a 256-event ring for SSE resume (PROTOCOL §5.5).
public final class EventHub: @unchecked Sendable {
	public static let ringSize = 256
	public static let maxStreamsPerDevice = 2

	/// One SSE subscriber, drained by its HTTP connection.
	public final class Stream: @unchecked Sendable {
		public let deviceID: String
		let created = Date()
		private let condition = NSCondition()
		private var queue: [Data] = []
		private(set) var closed = false
		private(set) var closeReason: String?

		init(deviceID: String) {
			self.deviceID = deviceID
		}

		func put(_ frame: Data) {
			condition.lock()
			defer { condition.unlock() }
			guard !closed else { return }
			queue.append(frame)
			if queue.count > 4 * EventHub.ringSize {
				closed = true
				closeReason = "overflow"
			}
			condition.broadcast()
		}

		public enum Next: Equatable {
			case frame(Data)
			case timeout
			case closed
		}

		/// The next frame, `.timeout` after `timeout` seconds, `.closed` once closed and drained.
		public func next(timeout: TimeInterval) -> Next {
			condition.lock()
			defer { condition.unlock() }
			let deadline = Date().addingTimeInterval(timeout)
			while queue.isEmpty && !closed {
				if !condition.wait(until: deadline) { break }
			}
			if !queue.isEmpty { return .frame(queue.removeFirst()) }
			return closed ? .closed : .timeout
		}

		func close(_ reason: String) {
			condition.lock()
			if !closed {
				closed = true
				closeReason = reason
				queue.removeAll()
			}
			condition.broadcast()
			condition.unlock()
		}
	}

	private let lock = NSLock()
	private var seq = 0
	private var ring: [(Int, Data)] = []
	private var streams: [Stream] = []
	private var listeners: [(String, [String: Any]) -> Void] = []

	public init() {}

	public var lastSeq: Int {
		lock.lock()
		defer { lock.unlock() }
		return seq
	}

	static func frame(_ event: String, _ data: [String: Any], seq: Int?) -> Data {
		var out = ""
		if let seq { out += "id: \(seq)\n" }
		out += "event: \(event)\n"
		out += "data: " + String(decoding: WireJSON.encode(data), as: UTF8.self) + "\n\n"
		return Data(out.utf8)
	}

	public func addListener(_ listener: @escaping (String, [String: Any]) -> Void) {
		lock.lock()
		listeners.append(listener)
		lock.unlock()
	}

	@discardableResult
	public func publish(_ event: String, _ data: [String: Any] = [:]) -> Int {
		lock.lock()
		seq += 1
		let current = seq
		let frame = Self.frame(event, data, seq: current)
		ring.append((current, frame))
		if ring.count > Self.ringSize { ring.removeFirst(ring.count - Self.ringSize) }
		let targets = streams
		let observers = listeners
		lock.unlock()
		for stream in targets { stream.put(frame) }
		for observer in observers { observer(event, data) }
		return current
	}

	/// Registers a stream and returns it with the `last_seq` for its `hello` frame. Frames after
	/// `Last-Event-ID` are queued first; an id outside the ring gets one `resync` frame instead.
	public func subscribe(deviceID: String, lastEventID: String?) -> (Stream, Int) {
		let stream = Stream(deviceID: deviceID)
		var evicted: [Stream] = []
		lock.lock()
		let last = seq
		if let lastEventID {
			let wanted = Int(lastEventID.trimmingCharacters(in: .whitespaces)) ?? -1
			let oldest = ring.first?.0 ?? last + 1
			if wanted < 0 || wanted > last || wanted + 1 < oldest {
				stream.put(Self.frame("resync", [:], seq: last))
			} else {
				for (id, frame) in ring where id > wanted { stream.put(frame) }
			}
		}
		var mine = streams.filter { $0.deviceID == deviceID }.sorted { $0.created < $1.created }
		while mine.count >= Self.maxStreamsPerDevice {
			let old = mine.removeFirst()
			streams.removeAll { $0 === old }
			evicted.append(old)
		}
		streams.append(stream)
		lock.unlock()
		for old in evicted { old.close("replaced") }
		return (stream, last)
	}

	public func unsubscribe(_ stream: Stream) {
		lock.lock()
		streams.removeAll { $0 === stream }
		lock.unlock()
		stream.close("unsubscribed")
	}

	@discardableResult
	public func closeDevice(_ deviceID: String, reason: String = "revoked") -> Int {
		lock.lock()
		let mine = streams.filter { $0.deviceID == deviceID }
		streams.removeAll { $0.deviceID == deviceID }
		lock.unlock()
		for stream in mine { stream.close(reason) }
		return mine.count
	}

	public func streamCount(deviceID: String? = nil) -> Int {
		lock.lock()
		defer { lock.unlock() }
		return streams.filter { deviceID == nil || $0.deviceID == deviceID }.count
	}

	public func closeAll() {
		lock.lock()
		let all = streams
		streams = []
		lock.unlock()
		for stream in all { stream.close("shutdown") }
	}
}
