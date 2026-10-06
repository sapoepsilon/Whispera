import AVFoundation
import Foundation

/// Text from the Mac's own speech engine.
public struct LocalTranscript: Sendable, Equatable {
	public struct Segment: Sendable, Equatable {
		public var start: Double
		public var end: Double
		public var text: String

		public init(start: Double, end: Double, text: String) {
			self.start = start
			self.end = end
			self.text = text
		}
	}

	public var text: String
	public var language: String?
	public var segments: [Segment]

	public init(text: String, language: String?, segments: [Segment] = []) {
		self.text = text
		self.language = language
		self.segments = segments
	}
}

/// The Mac's on-device engine as the voice server sees it. The helper app plugs WhisperKit in
/// here; tests plug in a fake. Implementations serialise their own work.
public protocol LocalSpeechEngine: Sendable {
	/// The model ids `GET /v1/models` lists, first one the default. Empty when no model is
	/// installed, which turns the voice server off.
	func modelIDs() -> [String]
	/// 16 kHz mono float samples in, text out.
	func transcribe(samples: [Float], language: String?, prompt: String?, temperature: Float?) async throws
		-> LocalTranscript
}

/// `POST /v1/audio/transcriptions` and `GET /v1/models` (PROTOCOL §9, plus the Mac voice server):
/// with an upstream configured the helper is the v1 passthrough, byte for byte; without one it
/// answers from the Mac's own engine in OpenAI's shape, so the phone's OpenAI-compatible engine
/// needs nothing but the base URL and its `wlk_` key.
public final class SpeechService: @unchecked Sendable {
	public static let modelAlias = "whisper-1"
	static let responseFormats: Set<String> = ["json", "text", "verbose_json"]

	let upstreamBaseURL: String
	let upstreamKeyFile: String
	public let timeout: Double
	let engine: LocalSpeechEngine?
	let log: OpsLog
	private let session: URLSession

	public init(
		upstreamBaseURL: String, upstreamKeyFile: String, timeout: Double, engine: LocalSpeechEngine?,
		log: OpsLog = .null
	) {
		var base = upstreamBaseURL
		while base.hasSuffix("/") { base.removeLast() }
		self.upstreamBaseURL = base
		self.upstreamKeyFile = upstreamKeyFile
		self.timeout = timeout
		self.engine = engine
		self.log = log
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = timeout
		configuration.timeoutIntervalForResource = timeout
		configuration.urlCache = nil
		session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
	}

	public var usesUpstream: Bool { !upstreamBaseURL.isEmpty }
	public var localModels: [String] { engine?.modelIDs() ?? [] }
	public var isConfigured: Bool { usesUpstream || !localModels.isEmpty }
	public var mode: String { usesUpstream ? "upstream" : (localModels.isEmpty ? "unconfigured" : "local") }

	public struct Reply {
		public var status: Int
		public var contentType: String
		public var body: Data
	}

	public func transcribe(body: Data, contentType: String?, deviceID: String) throws -> Reply {
		if usesUpstream {
			return try forward(
				path: "/audio/transcriptions", method: "POST", body: body, contentType: contentType,
				deviceID: deviceID)
		}
		guard let engine, !localModels.isEmpty else {
			throw APIError(503, "upstream_unconfigured", "no speech model is installed in Whispera on this Mac")
		}
		let started = Date()
		let form = try MultipartForm(body: body, contentType: contentType)
		guard let file = form.file else { throw APIError(400, "bad_request", "multipart field file is required") }
		let format = form.fields["response_format"] ?? "json"
		guard Self.responseFormats.contains(format) else {
			throw APIError(400, "bad_request", "response_format must be json, text or verbose_json")
		}
		let samples = try AudioDecoder.samples16k(file.data, filename: file.filename)
		let language = form.fields["language"].flatMap { $0.isEmpty ? nil : $0 }
		let prompt = form.fields["prompt"].flatMap { $0.isEmpty ? nil : $0 }
		let temperature = form.fields["temperature"].flatMap(Float.init)
		let transcript = try Self.runBlocking(timeout: timeout) {
			try await engine.transcribe(
				samples: samples, language: language, prompt: prompt, temperature: temperature)
		}
		let duration = Double(samples.count) / AudioDecoder.sampleRate
		log(
			"stt",
			[
				"device": deviceID, "status": 200, "ms": Int(Date().timeIntervalSince(started) * 1000),
				"detail": "local bytes=\(body.count)",
			])
		switch format {
		case "text":
			return Reply(
				status: 200, contentType: "text/plain; charset=utf-8", body: Data((transcript.text + "\n").utf8)
			)
		case "verbose_json":
			let segments: [[String: Any]] = transcript.segments.enumerated().map { index, segment in
				["id": index, "start": segment.start, "end": segment.end, "text": segment.text]
			}
			let object: [String: Any] = [
				"task": "transcribe", "language": transcript.language ?? language ?? NSNull(),
				"duration": duration,
				"text": transcript.text, "segments": segments,
			]
			return Reply(status: 200, contentType: "application/json", body: WireJSON.encode(object))
		default:
			return Reply(
				status: 200, contentType: "application/json", body: WireJSON.encode(["text": transcript.text]))
		}
	}

	public func models(deviceID: String) throws -> Reply {
		if usesUpstream {
			return try forward(path: "/models", method: "GET", body: nil, contentType: nil, deviceID: deviceID)
		}
		let models = localModels
		guard !models.isEmpty else {
			throw APIError(503, "upstream_unconfigured", "no speech model is installed in Whispera on this Mac")
		}
		let data = ([Self.modelAlias] + models.filter { $0 != Self.modelAlias }).map { id -> [String: Any] in
			[
				"id": id, "object": "model", "created": 0, "owned_by": "whispera",
				"task": "automatic-speech-recognition",
			]
		}
		return Reply(
			status: 200, contentType: "application/json", body: WireJSON.encode(["object": "list", "data": data]))
	}

	// MARK: Upstream passthrough (§9)

	private func upstreamKey() -> String? {
		guard !upstreamKeyFile.isEmpty, let text = try? String(contentsOfFile: upstreamKeyFile, encoding: .utf8)
		else { return nil }
		let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return key.isEmpty ? nil : key
	}

	private func forward(path: String, method: String, body: Data?, contentType: String?, deviceID: String) throws
		-> Reply
	{
		guard let url = URL(string: upstreamBaseURL + path) else {
			throw APIError(502, "upstream_error", "STT upstream URL is invalid")
		}
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.timeoutInterval = timeout
		if let body {
			request.httpBody = body
			request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
		}
		if let key = upstreamKey() { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
		let started = Date()
		let prepared = request
		let seconds = Int(timeout)
		let (data, response) = try Self.runBlocking(timeout: timeout + 5) {
			[session] () async throws -> (Data, URLResponse) in
			do {
				return try await session.data(for: prepared)
			} catch let error as URLError where error.code == .timedOut {
				throw APIError(504, "upstream_timeout", "STT upstream did not answer in \(seconds) s")
			} catch is URLError {
				throw APIError(502, "upstream_error", "STT upstream unreachable")
			}
		}
		let http = response as? HTTPURLResponse
		let status = http?.statusCode ?? 502
		log(
			path == "/models" ? "stt.models" : "stt",
			[
				"device": deviceID, "status": status, "ms": Int(Date().timeIntervalSince(started) * 1000),
				"detail": body.map { "bytes=\($0.count)" },
			])
		return Reply(
			status: status, contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json",
			body: data)
	}

	/// Runs async work from a blocking request thread, bounded by `timeout`.
	static func runBlocking<T>(timeout: Double, _ work: @escaping @Sendable () async throws -> T) throws -> T {
		let semaphore = DispatchSemaphore(value: 0)
		let box = Box<T>()
		let task = Task {
			do {
				box.result = .success(try await work())
			} catch {
				box.result = .failure(error)
			}
			semaphore.signal()
		}
		guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.result else {
			task.cancel()
			throw APIError(504, "upstream_timeout", "speech engine did not answer in \(Int(timeout)) s")
		}
		switch result {
		case .success(let value): return value
		case .failure(let error as APIError): throw error
		case .failure(let error):
			throw APIError(502, "upstream_error", "speech engine failed: \(error.localizedDescription)")
		}
	}

	private final class Box<T>: @unchecked Sendable {
		var result: Result<T, Error>?
	}

	private final class NoRedirects: NSObject, URLSessionTaskDelegate {
		func urlSession(
			_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
			newRequest request: URLRequest
		) async -> URLRequest? { nil }
	}
}

/// A `multipart/form-data` body: text fields and the one `file` part.
struct MultipartForm {
	struct File {
		var filename: String
		var contentType: String?
		var data: Data
	}

	var fields: [String: String] = [:]
	var file: File?

	init(body: Data, contentType: String?) throws {
		guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data"),
			let boundary = Self.parameter("boundary", in: contentType), !boundary.isEmpty
		else { throw APIError(400, "bad_request", "body must be multipart/form-data with a boundary") }
		let delimiter = Data("--\(boundary)".utf8)
		let crlf = Data("\r\n".utf8)
		guard var cursor = body.range(of: delimiter)?.upperBound else {
			throw APIError(400, "bad_request", "multipart boundary not found")
		}
		while true {
			if body[cursor...].starts(with: Data("--".utf8)) { break }
			guard body[cursor...].starts(with: crlf) else {
				throw APIError(400, "bad_request", "malformed multipart body")
			}
			cursor = body.index(cursor, offsetBy: 2)
			guard let headEnd = body.range(of: Data("\r\n\r\n".utf8), in: cursor..<body.endIndex) else {
				throw APIError(400, "bad_request", "malformed multipart part")
			}
			let head = String(decoding: body[cursor..<headEnd.lowerBound], as: UTF8.self)
			guard let next = body.range(of: crlf + delimiter, in: headEnd.upperBound..<body.endIndex) else {
				throw APIError(400, "bad_request", "unterminated multipart part")
			}
			let content = body.subdata(in: headEnd.upperBound..<next.lowerBound)
			var disposition = ""
			var partType: String?
			for line in head.components(separatedBy: "\r\n") {
				let lower = line.lowercased()
				if lower.hasPrefix("content-disposition:") { disposition = line }
				if lower.hasPrefix("content-type:") {
					partType = String(line.dropFirst("content-type:".count)).trimmingCharacters(
						in: .whitespaces)
				}
			}
			if let name = Self.parameter("name", in: disposition) {
				if let filename = Self.parameter("filename", in: disposition) {
					if name == "file" {
						file = File(filename: filename, contentType: partType, data: content)
					}
				} else {
					fields[name] = String(decoding: content, as: UTF8.self)
				}
			}
			cursor = next.upperBound
		}
	}

	static func parameter(_ name: String, in header: String) -> String? {
		for piece in header.split(separator: ";").dropFirst() {
			let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			guard pair.count == 2, pair[0].lowercased() == name else { continue }
			var value = pair[1]
			if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
				value = String(value.dropFirst().dropLast())
			}
			return value
		}
		return nil
	}
}

/// Any audio Core Audio can read (WAV, M4A, MP3, CAF, FLAC, …) → 16 kHz mono float.
enum AudioDecoder {
	static let sampleRate: Double = 16_000
	static let maxSeconds: Double = 30 * 60

	static func samples16k(_ data: Data, filename: String) throws -> [Float] {
		let ext = (filename as NSString).pathExtension.isEmpty ? "wav" : (filename as NSString).pathExtension
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(
			"wl-stt-\(UUID().uuidString).\(ext)")
		try data.write(to: url, options: .atomic)
		chmod(url.path, 0o600)
		defer { try? FileManager.default.removeItem(at: url) }
		let file: AVAudioFile
		do {
			file = try AVAudioFile(forReading: url)
		} catch {
			throw APIError(400, "bad_request", "the audio file could not be decoded")
		}
		guard file.length > 0 else { throw APIError(400, "bad_request", "the audio file holds no samples") }
		guard Double(file.length) / file.processingFormat.sampleRate <= maxSeconds else {
			throw APIError(413, "payload_too_large", "audio longer than 30 minutes")
		}
		guard
			let target = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
			let converter = AVAudioConverter(from: file.processingFormat, to: target),
			let input = AVAudioPCMBuffer(
				pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
		else { throw APIError(400, "bad_request", "the audio format is not supported") }
		do {
			try file.read(into: input)
		} catch {
			throw APIError(400, "bad_request", "the audio file could not be decoded")
		}
		let capacity =
			AVAudioFrameCount(Double(input.frameLength) * sampleRate / file.processingFormat.sampleRate) + 1024
		guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
			throw APIError(400, "bad_request", "the audio format is not supported")
		}
		var fed = false
		var conversionError: NSError?
		let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
			if fed {
				outStatus.pointee = .endOfStream
				return nil
			}
			fed = true
			outStatus.pointee = .haveData
			return input
		}
		guard status != .error, let channel = output.floatChannelData else {
			throw APIError(400, "bad_request", "the audio file could not be converted")
		}
		return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
	}
}
