import AppKit
import Foundation
import WhisperKit

/// Headless mode of the app binary: `Whispera.app/Contents/MacOS/Whispera --transcribe-file a.wav`.
enum WhisperaCLI {
	static func isCLIInvocation(_ arguments: [String]) -> Bool {
		CLIOptions.isCLIInvocation(arguments)
	}

	static func run(arguments: [String], defaults: UserDefaults = .standard) async -> Int32 {
		let options: CLIOptions
		do {
			options = try CLIOptions.parse(arguments)
		} catch {
			writeError("whispera: \(error.localizedDescription)\n\n\(CLIOptions.usage)")
			return 2
		}

		// Arguments can hold private file paths, so only the action is logged.
		AppLogger.shared.general.info("CLI invocation: \(options.action.logName)")

		do {
			switch options.action {
			case .help:
				write(CLIOptions.usage)
			case .listModels:
				await listModels(options: options, defaults: defaults)
			case .listDevices:
				listDevices(options: options)
			case .transcribe:
				try await transcribe(options: options, defaults: defaults)
			case .remote(let command):
				try await sendRemote(command, defaults: defaults)
			}
			return 0
		} catch {
			writeError("whispera: \(error.localizedDescription)")
			AppLogger.shared.general.error("CLI failed: \(error.localizedDescription)")
			return 1
		}
	}

	@MainActor
	private static func listModels(options: CLIOptions, defaults: UserDefaults) {
		let models = CLIModelCatalog.downloadedModels()
		let current = CLIModelCatalog.defaultModel(downloaded: models, defaults: defaults)
		if options.json {
			struct Entry: Encodable {
				let id: String
				let name: String
				let isDefault: Bool
				enum CodingKeys: String, CodingKey {
					case id, name
					case isDefault = "default"
				}
			}
			writeJSON(
				models.map {
					Entry(id: $0, name: WhisperKitTranscriber.getModelDisplayName(for: $0), isDefault: $0 == current)
				})
			return
		}
		guard !models.isEmpty else {
			write("No models downloaded. Download one in Whispera Settings.")
			return
		}
		for model in models {
			write("\(model == current ? "*" : " ") \(model)")
		}
	}

	private static func listDevices(options: CLIOptions) {
		if options.json {
			struct Entry: Encodable {
				let index: Int
				let id: String
				let summary: String
			}
			writeJSON(CLIComputeDevice.all.map { Entry(index: $0.index, id: $0.id, summary: $0.summary) })
			return
		}
		for device in CLIComputeDevice.all {
			write("\(device.index)  \(device.id.padding(toLength: 8, withPad: " ", startingAt: 0))\(device.summary)")
		}
	}

	private static func transcribe(options: CLIOptions, defaults: UserDefaults) async throws {
		let downloaded = CLIModelCatalog.downloadedModels()
		guard !downloaded.isEmpty else { throw HeadlessTranscriberError.noModelsDownloaded }
		let model = options.model ?? CLIModelCatalog.defaultModel(downloaded: downloaded, defaults: defaults)!
		guard downloaded.contains(model) else {
			throw HeadlessTranscriberError.modelNotDownloaded(model, available: downloaded)
		}
		guard let device = CLIComputeDevice.device(at: options.deviceIndex) else {
			throw HeadlessTranscriberError.unknownDevice(options.deviceIndex ?? 0)
		}
		guard let language = CLIDecodingSettings.resolveLanguage(options.language, defaults: defaults) else {
			throw HeadlessTranscriberError.unknownLanguage(options.language ?? "")
		}

		for file in options.files where !FileManager.default.isReadableFile(atPath: file) {
			throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: file])
		}

		debugLog(options, "Loading \(model) on device \(device.index) (\(device.id))")
		let transcriber = try await HeadlessTranscriber(
			model: model, device: device, downloadBase: CLIModelCatalog.defaultDownloadBase, verbose: options.debug)
		debugLog(options, String(format: "Model loaded in %.0f ms", transcriber.loadMs))

		let decoding: DecodingOptions
		switch language {
		case .code(let code):
			decoding = CLIDecodingSettings.options(
				language: code, detectLanguage: options.translate, translate: options.translate, defaults: defaults)
		case .detect:
			decoding = CLIDecodingSettings.options(
				language: nil, detectLanguage: true, translate: options.translate, defaults: defaults)
		}

		var runs: [CLITranscriptionRun] = []
		for file in options.files {
			let run = try await transcriber.run(file: file, repeatCount: options.repeatCount, options: decoding)
			runs.append(run)
			debugLog(
				options,
				String(
					format: "%@: %.2fs audio, best %.0f ms, RTF %.3f", (file as NSString).lastPathComponent,
					run.audioSeconds, run.bestMs, run.rtf))
			if !options.json {
				if options.files.count > 1 { write("==> \(file) <==") }
				write(run.text)
				if options.repeatCount > 1 {
					writeError(String(format: "best_ms=%.0f rtf=%.3f runs=%d", run.bestMs, run.rtf, run.runsMs.count))
				}
			}
		}

		if options.json {
			writeJSON(
				CLITranscriptionReport(model: model, device: device.id, loadMs: transcriber.loadMs, results: runs))
		}
	}

	private static func sendRemote(_ command: RemoteCommand, defaults: UserDefaults) async throws {
		let url = try remoteURL(for: command, defaults: defaults)
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = false
		// Target this bundle so the command reaches the copy of Whispera the CLI belongs to.
		_ = try await NSWorkspace.shared.open(
			[url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
	}

	/// The CLI runs as the same user, so it can read the token file and prove it is not a web page.
	static func remoteURL(
		for command: RemoteCommand, defaults: UserDefaults,
		tokenDirectory: URL = RemoteControlToken.defaultDirectory
	) throws -> URL {
		guard command.isAlwaysAllowedFromURL || RemoteControlSettings.isURLSchemeEnabled(in: defaults) else {
			throw CLIRemoteError.urlControlDisabled
		}
		guard command.requiresToken else { return command.url }
		guard let token = RemoteControlToken.load(in: tokenDirectory) else {
			throw CLIRemoteError.tokenUnavailable
		}
		return command.url(token: token)
	}

	private static func debugLog(_ options: CLIOptions, _ message: String) {
		guard options.debug else { return }
		writeError("[whispera] \(message)")
	}

	private static func writeJSON<T: Encodable>(_ value: T) {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
			writeError("whispera: could not encode JSON output")
			return
		}
		write(string)
	}

	private static func write(_ text: String) {
		FileHandle.standardOutput.write(Data((text + "\n").utf8))
	}

	private static func writeError(_ text: String) {
		FileHandle.standardError.write(Data((text + "\n").utf8))
	}
}

enum CLIRemoteError: LocalizedError {
	case urlControlDisabled
	case tokenUnavailable

	var errorDescription: String? {
		switch self {
		case .urlControlDisabled:
			return "Remote control is off. Enable \"Allow whispera:// links\" in Whispera Settings > Automation."
		case .tokenUnavailable:
			return "Could not read or create the remote control token in ~/Library/Application Support/Whispera."
		}
	}
}
