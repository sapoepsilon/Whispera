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
	/// What the phone is told the engine is, e.g. "WhisperKit".
	var engineName: String { get }
	/// The installed model the engine would use, first one first. Empty when no model is ready.
	func modelIDs() -> [String]
	/// 16 kHz mono float samples in, text out.
	func transcribe(samples: [Float], language: String?, prompt: String?, temperature: Float?) async throws
		-> LocalTranscript
}

extension LocalSpeechEngine {
	public var engineName: String { "On-device" }
}

/// `POST /v1/audio/transcriptions` and `GET /v1/models` (PROTOCOL §9, plus the Mac voice server).
///
/// The Mac is the server for whatever engine is selected in Whispera on it (`MacSpeechSelecting`):
/// the phone's `model` is ignored and the audio goes to the Mac's on-device model, or to the
/// speech server Whispera is set up to use with the Mac's model and key. The key never leaves the
/// Mac. `GET /v1/models` lists one virtual model, `whispera-mac`, carrying the engine's name.
///
/// Without a selection (the e2e `link-helper-serve`) a configured `stt.upstream_base_url` is the
/// remote engine and otherwise the on-device one serves.
public final class SpeechService: @unchecked Sendable {
	/// The one model id `GET /v1/models` lists; any model a phone sends is answered by the Mac's engine.
	public static let macModelID = "whispera-mac"
	public static let noModelReady =
		"Mac has no transcription model ready — open Whispera ▸ Settings to download one."
	public static let noServerModel =
		"The Mac's speech server has no model set — open Whispera ▸ Settings ▸ Servers on the Mac and pick one."
	static let responseFormats: Set<String> = ["json", "text", "verbose_json"]

	let upstreamBaseURL: String
	let upstreamKeyFile: String
	let upstreamModel: String
	public let timeout: Double
	let engine: LocalSpeechEngine?
	let selection: MacSpeechSelecting?
	let keyStore: SpeechKeyStoring?
	let log: OpsLog
	private let session: URLSession

	public init(
		upstreamBaseURL: String, upstreamKeyFile: String, upstreamModel: String = "", timeout: Double,
		engine: LocalSpeechEngine?, selection: MacSpeechSelecting? = nil, keyStore: SpeechKeyStoring? = nil,
		log: OpsLog = .null
	) {
		var base = upstreamBaseURL
		while base.hasSuffix("/") { base.removeLast() }
		self.upstreamBaseURL = base
		self.upstreamKeyFile = upstreamKeyFile
		self.upstreamModel = upstreamModel
		self.timeout = timeout
		self.engine = engine
		self.selection = selection
		self.keyStore = keyStore
		self.log = log
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = timeout
		configuration.timeoutIntervalForResource = timeout
		configuration.urlCache = nil
		session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
	}

	/// Where a request made now goes.
	public func currentRoute() -> MacSpeechRoute {
		if let selection { return selection.route() }
		if !upstreamBaseURL.isEmpty {
			return .remote(RemoteSpeechServer(baseURL: upstreamBaseURL, model: upstreamModel))
		}
		return .onDevice
	}

	/// The engine as the phone and the Mac's settings see it.
	public struct EngineInfo: Equatable, Sendable {
		/// `on-device`, `remote` or `none`.
		public var kind: String
		public var name: String
		public var ready: Bool
		/// Why it is not ready, in words for the owner.
		public var message: String?
	}

	public func engineInfo() -> EngineInfo {
		switch currentRoute() {
		case .onDevice:
			let name = engine?.engineName ?? "On-device"
			if let model = localModels.first {
				return EngineInfo(kind: "on-device", name: "\(name) · \(model)", ready: true, message: nil)
			}
			return EngineInfo(kind: "on-device", name: name, ready: false, message: Self.noModelReady)
		case .remote(let server):
			if server.model.isEmpty {
				// A configured upstream without a model passes the phone's model through (the v1 daemon).
				let ready = selection == nil
				return EngineInfo(
					kind: "remote", name: server.label, ready: ready,
					message: ready ? nil : Self.noServerModel)
			}
			return EngineInfo(
				kind: "remote", name: "\(server.label) · \(server.model)", ready: true, message: nil)
		case .unavailable(let message):
			return EngineInfo(kind: "none", name: "Not set up", ready: false, message: message)
		}
	}

	public var localModels: [String] { engine?.modelIDs() ?? [] }
	public var isConfigured: Bool { engineInfo().ready }
	/// `local`, `remote` or `unconfigured` (health and the helper status).
	public var mode: String {
		let info = engineInfo()
		guard info.ready else { return "unconfigured" }
		return info.kind == "remote" ? "remote" : "local"
	}

	public struct Reply {
		public var status: Int
		public var contentType: String
		public var body: Data
	}

	public func transcribe(body: Data, contentType: String?, deviceID: String) throws -> Reply {
		switch currentRoute() {
		case .unavailable(let message):
			throw APIError(503, "engine_unavailable", message)
		case .remote(let server):
			return try transcribeRemotely(server, body: body, contentType: contentType, deviceID: deviceID)
		case .onDevice:
			return try transcribeOnDevice(body: body, contentType: contentType, deviceID: deviceID)
		}
	}

	private func transcribeRemotely(_ server: RemoteSpeechServer, body: Data, contentType: String?, deviceID: String)
		throws -> Reply
	{
		if server.model.isEmpty, selection != nil { throw APIError(503, "engine_unavailable", Self.noServerModel) }
		let form = try MultipartForm(body: body, contentType: contentType)
		guard form.file != nil else { throw APIError(400, "bad_request", "multipart field file is required") }
		let model: String?
		if !server.model.isEmpty {
			model = server.model
		} else {
			// v1 passthrough: the phone's own model, unless it is the virtual one.
			let sent = form.fields["model"] ?? ""
			model = sent.isEmpty || sent == Self.macModelID ? nil : sent
		}
		let rewritten = form.encoded(replacing: "model", with: model)
		return try forward(
			server, path: "/audio/transcriptions", method: "POST", body: rewritten,
			contentType: "multipart/form-data; boundary=\(form.boundary)", deviceID: deviceID)
	}

	private func transcribeOnDevice(body: Data, contentType: String?, deviceID: String) throws -> Reply {
		guard let engine, !localModels.isEmpty else {
			throw APIError(503, "model_not_ready", Self.noModelReady)
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

	/// One virtual model whatever the engine, so the phone shows "your Mac's engine" and never
	/// has to know a model name. Answers even when the engine is not ready, with `ready: false`
	/// and the reason.
	public func models(deviceID: String) throws -> Reply {
		var info = engineInfo()
		if case .remote(let server) = currentRoute(), info.ready {
			do {
				let listed = try forward(server, path: "/models", method: "GET", body: nil, contentType: nil, deviceID: deviceID, requestTimeout: 5)
				if !(200..<300).contains(listed.status) {
					info.ready = false
					info.message = "The Mac's speech server returned HTTP \(listed.status). Check its address, port, and API key in Mac Settings ▸ Servers."
				} else if let object = WireJSON.decodeObject(listed.body), let models = object["data"] as? [[String: Any]] {
					if !models.contains(where: { $0["id"] as? String == server.model }) {
						info.ready = false
						info.message = "The Mac's speech server doesn't have the selected model (\(server.model)). Choose an installed model in Mac Settings ▸ Servers."
					}
				} else {
					info.ready = false; info.message = "The Mac's speech server returned an unexpected model list. Check the full address in Mac Settings ▸ Servers."
				}
			} catch {
				info.ready = false
				info.message = (error as? APIError)?.message ?? "The Mac couldn't reach its speech server. Check its address and port in Mac Settings ▸ Servers."
			}
		}
		var model: [String: Any] = [
			"id": Self.macModelID, "object": "model", "created": 0, "owned_by": "whispera",
			"task": "automatic-speech-recognition", "engine": info.name, "engine_kind": info.kind,
			"ready": info.ready,
		]
		if let message = info.message { model["message"] = message }
		log("stt.models", ["device": deviceID, "status": 200, "detail": "\(info.kind) ready=\(info.ready)"])
		return Reply(
			status: 200, contentType: "application/json",
			body: WireJSON.encode(["object": "list", "data": [model]]))
	}

	// MARK: Remote engine

	/// The key for `server`: the one Whispera handed over for that exact base URL, or the
	/// configured key file for the v1 upstream.
	private func key(for server: RemoteSpeechServer) -> String? {
		if selection != nil { return keyStore?.key(for: server) }
		guard !upstreamKeyFile.isEmpty, let text = try? String(contentsOfFile: upstreamKeyFile, encoding: .utf8)
		else { return nil }
		let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return key.isEmpty ? nil : key
	}

	private func forward(
		_ server: RemoteSpeechServer, path: String, method: String, body: Data?, contentType: String?,
		deviceID: String, requestTimeout: Double? = nil
	) throws -> Reply {
		guard let url = URL(string: server.baseURL + path) else {
			throw APIError(502, "upstream_error", "The Mac's speech server address is invalid: \(server.baseURL)")
		}
		var request = URLRequest(url: url)
		request.httpMethod = method
		let limit = requestTimeout ?? timeout
		request.timeoutInterval = limit
		if let body {
			request.httpBody = body
			request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
		}
		if let key = key(for: server) { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
		let started = Date()
		let prepared = request
		let seconds = Int(limit)
		let base = server.baseURL
		let (data, response) = try Self.runBlocking(timeout: limit + 5) {
			[session] () async throws -> (Data, URLResponse) in
			do {
				return try await session.data(for: prepared)
			} catch let error as URLError where error.code == .timedOut {
				throw APIError(
					504, "upstream_timeout",
					"The Mac's speech server at \(base) did not answer in \(seconds) s")
			} catch is URLError {
				throw APIError(502, "upstream_error", "The Mac couldn't reach its speech server at \(base)")
			}
		}
		let http = response as? HTTPURLResponse
		let status = http?.statusCode ?? 502
		log(
			"stt",
			[
				"device": deviceID, "status": status, "ms": Int(Date().timeIntervalSince(started) * 1000),
				"detail": "remote \(server.label) bytes=\(body?.count ?? 0)",
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

	/// One part as it arrived: its header block, its bytes and its field name.
	struct Part {
		var head: Data
		var content: Data
		var name: String?
	}

	var fields: [String: String] = [:]
	var file: File?
	let boundary: String
	private(set) var parts: [Part] = []

	init(body: Data, contentType: String?) throws {
		guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data"),
			let boundary = Self.parameter("boundary", in: contentType), !boundary.isEmpty
		else { throw APIError(400, "bad_request", "body must be multipart/form-data with a boundary") }
		self.boundary = boundary
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
			let partName = Self.parameter("name", in: disposition)
			parts.append(
				Part(head: body.subdata(in: cursor..<headEnd.lowerBound), content: content, name: partName))
			if let name = partName {
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

	/// The same body with every `field` part dropped and, when `value` is non-nil, one new
	/// `field` part in its place. Every other part keeps its bytes and order.
	func encoded(replacing field: String, with value: String?) -> Data {
		var out = Data()
		func open() { out.append(Data("--\(boundary)\r\n".utf8)) }
		for part in parts where part.name != field {
			open()
			out.append(part.head)
			out.append(Data("\r\n\r\n".utf8))
			out.append(part.content)
			out.append(Data("\r\n".utf8))
		}
		if let value {
			open()
			out.append(Data("Content-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
		}
		out.append(Data("--\(boundary)--\r\n".utf8))
		return out
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
