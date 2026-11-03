import Darwin
import Foundation

/// A connected AF_UNIX stream socket with deadline-bounded line reads. The broker, herdr and
/// admin protocols are all newline-delimited JSON over one of these.
final class UnixConnection: @unchecked Sendable {
	let fd: Int32
	private var buffer = Data()
	private let sendLock = NSLock()
	private let closeLock = NSLock()
	private(set) var isClosed = false

	init(fd: Int32) {
		self.fd = fd
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
	}

	deinit { close() }

	enum LineResult: Equatable {
		case line(Data)
		case timeout
		case eof
	}

	struct LineTooLong: Error {}

	/// Opens a connection to `path`, failing after `timeout` seconds.
	static func connect(path: String, timeout: TimeInterval) throws -> UnixConnection {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw FileStore.posixError("socket") }
		var address = try UnixConnection.address(for: path)
		let flags = fcntl(fd, F_GETFL)
		_ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
		let result = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		if result != 0 {
			guard errno == EINPROGRESS else {
				let error = FileStore.posixError("connect \(path)")
				Darwin.close(fd)
				throw error
			}
			var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
			let ready = poll(&poller, 1, Int32(timeout * 1000))
			var soError: Int32 = 0
			var length = socklen_t(MemoryLayout<Int32>.size)
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
			if ready <= 0 || soError != 0 {
				Darwin.close(fd)
				if ready == 0 { throw SocketTimeout() }
				errno = soError
				throw FileStore.posixError("connect \(path)")
			}
		}
		_ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
		return UnixConnection(fd: fd)
	}

	static func address(for path: String) throws -> sockaddr_un {
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(path.utf8)
		let capacity = MemoryLayout.size(ofValue: address.sun_path)
		guard bytes.count < capacity else {
			throw NSError(
				domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG),
				userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(path)"])
		}
		withUnsafeMutableBytes(of: &address.sun_path) { raw in
			for (index, byte) in bytes.enumerated() { raw[index] = byte }
			raw[bytes.count] = 0
		}
		return address
	}

	struct SocketTimeout: Error {}

	/// The peer's effective uid (`getpeereid`, the same answer as `LOCAL_PEERCRED`).
	var peerUID: uid_t? {
		var uid: uid_t = 0
		var gid: gid_t = 0
		return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
	}

	func send(_ data: Data, timeout: TimeInterval = 2) throws {
		sendLock.lock()
		defer { sendLock.unlock() }
		guard !isClosed else { throw FileStore.posixError("send on closed socket") }
		try data.withUnsafeBytes { raw in
			var offset = 0
			let deadline = Date().addingTimeInterval(timeout)
			while offset < raw.count {
				var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
				let left = deadline.timeIntervalSinceNow
				guard left > 0, poll(&poller, 1, Int32(left * 1000)) > 0 else { throw SocketTimeout() }
				let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
				if n < 0 {
					if errno == EINTR || errno == EAGAIN { continue }
					throw FileStore.posixError("send")
				}
				offset += n
			}
		}
	}

	func sendLine(_ object: [String: Any], timeout: TimeInterval = 2) throws {
		var data = WireJSON.encode(object)
		data.append(0x0A)
		try send(data, timeout: timeout)
	}

	var hasBufferedLine: Bool { buffer.contains(0x0A) }

	/// One line without its newline, `.timeout` when nothing complete arrives in time, `.eof` when
	/// the peer closed. Throws `LineTooLong` past `limit` bytes.
	func readLine(timeout: TimeInterval, limit: Int = 64 * 1024) throws -> LineResult {
		let deadline = Date().addingTimeInterval(timeout)
		while true {
			if let newline = buffer.firstIndex(of: 0x0A) {
				let line = buffer.subdata(in: buffer.startIndex..<newline)
				buffer.removeSubrange(buffer.startIndex...newline)
				if line.count > limit { throw LineTooLong() }
				return .line(line)
			}
			if buffer.count > limit { throw LineTooLong() }
			let left = deadline.timeIntervalSinceNow
			if left <= 0 { return .timeout }
			var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
			let ready = poll(&poller, 1, Int32(max(1, left * 1000)))
			if ready < 0 {
				if errno == EINTR { continue }
				return .eof
			}
			if ready == 0 { return .timeout }
			var chunk = [UInt8](repeating: 0, count: 65536)
			let n = recv(fd, &chunk, chunk.count, 0)
			if n < 0 {
				if errno == EINTR || errno == EAGAIN { continue }
				return .eof
			}
			if n == 0 { return .eof }
			buffer.append(contentsOf: chunk[0..<n])
		}
	}

	func close() {
		closeLock.lock()
		defer { closeLock.unlock() }
		guard !isClosed else { return }
		isClosed = true
		shutdown(fd, SHUT_RDWR)
		Darwin.close(fd)
	}
}

/// A listening AF_UNIX socket, mode 0600, that hands accepted connections from the owner's uid
/// to `handle` on a thread of their own (PROTOCOL §1.3: both sockets refuse other uids).
final class UnixListener: @unchecked Sendable {
	let path: String
	private var fd: Int32 = -1
	private let lock = NSLock()
	private var stopped = false

	init(path: String) {
		self.path = path
	}

	func start(
		name: String, onForeignPeer: @escaping (UnixConnection) -> Void = { $0.close() },
		handle: @escaping (UnixConnection) -> Void
	) throws {
		try FileManager.default.createDirectory(
			atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
		unlink(path)
		let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
		guard socketFD >= 0 else { throw FileStore.posixError("socket") }
		var address = try UnixConnection.address(for: path)
		let oldMask = umask(0o177)
		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		umask(oldMask)
		guard bound == 0 else {
			let error = FileStore.posixError("bind \(path)")
			Darwin.close(socketFD)
			throw error
		}
		chmod(path, 0o600)
		guard listen(socketFD, 16) == 0 else {
			let error = FileStore.posixError("listen \(path)")
			Darwin.close(socketFD)
			throw error
		}
		fd = socketFD
		let thread = Thread { [weak self] in self?.acceptLoop(onForeignPeer: onForeignPeer, handle: handle) }
		thread.name = name
		thread.start()
	}

	private func acceptLoop(
		onForeignPeer: @escaping (UnixConnection) -> Void, handle: @escaping (UnixConnection) -> Void
	) {
		while true {
			lock.lock()
			let listening = fd
			let done = stopped
			lock.unlock()
			if done || listening < 0 { return }
			var poller = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
			if poll(&poller, 1, 500) <= 0 { continue }
			let client = accept(listening, nil, nil)
			guard client >= 0 else { continue }
			let connection = UnixConnection(fd: client)
			guard connection.peerUID == getuid() else {
				onForeignPeer(connection)
				continue
			}
			let worker = Thread { handle(connection) }
			worker.name = "unix-conn"
			worker.start()
		}
	}

	func stop() {
		lock.lock()
		stopped = true
		if fd >= 0 {
			Darwin.close(fd)
			fd = -1
		}
		lock.unlock()
		unlink(path)
	}
}
