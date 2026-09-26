import AppKit
import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
	let uid: String
	let name: String
	var id: String { uid }
}

enum AudioOutputDeviceCatalog {
	static func outputDevices() -> [AudioOutputDevice] {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDevices,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var size: UInt32 = 0
		let system = AudioObjectID(kAudioObjectSystemObject)
		guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
			return []
		}
		var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
		guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

		let control = CoreAudioOutputControl()
		return ids.compactMap { id in
			guard hasOutputStreams(id), let uid = control.uid(for: id), let name = name(of: id) else {
				return nil
			}
			return AudioOutputDevice(uid: uid, name: name)
		}
	}

	private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyStreams,
			mScope: kAudioObjectPropertyScopeOutput,
			mElement: kAudioObjectPropertyElementMain
		)
		var size: UInt32 = 0
		return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
	}

	private static func name(of id: AudioDeviceID) -> String? {
		var name: CFString = "" as CFString
		var size = UInt32(MemoryLayout<CFString>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceNameCFString,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr ? name as String : nil
	}
}

enum FeedbackSoundSource: Equatable {
	case system(String)
	case file(URL)
}

struct FeedbackSoundSettings: Equatable {
	static let enabledKey = "soundFeedback"
	static let startSoundKey = "startSound"
	static let stopSoundKey = "stopSound"
	static let volumeKey = "feedbackSoundVolume"
	static let outputDeviceKey = "feedbackOutputDeviceUID"
	static let customStartPathKey = "customStartSoundPath"
	static let customStopPathKey = "customStopSoundPath"

	static let noneSoundName = "None"
	static let customSoundName = "Custom"
	/// Empty output device UID means "follow the system output".
	static let systemOutputUID = ""
	static let defaultVolume = 1.0

	var enabled: Bool
	var startSound: String
	var stopSound: String
	var volume: Double
	var outputDeviceUID: String
	var customStartPath: String
	var customStopPath: String

	init(defaults: UserDefaults) {
		enabled = defaults.bool(forKey: Self.enabledKey)
		startSound = defaults.string(forKey: Self.startSoundKey) ?? "Tink"
		stopSound = defaults.string(forKey: Self.stopSoundKey) ?? "Pop"
		let storedVolume = defaults.object(forKey: Self.volumeKey) as? Double ?? Self.defaultVolume
		volume = min(max(storedVolume, 0), 1)
		outputDeviceUID = defaults.string(forKey: Self.outputDeviceKey) ?? Self.systemOutputUID
		customStartPath = defaults.string(forKey: Self.customStartPathKey) ?? ""
		customStopPath = defaults.string(forKey: Self.customStopPathKey) ?? ""
	}

	func source(start: Bool) -> FeedbackSoundSource? {
		guard enabled, volume > 0 else { return nil }
		let name = start ? startSound : stopSound
		switch name {
		case Self.noneSoundName:
			return nil
		case Self.customSoundName:
			let path = start ? customStartPath : customStopPath
			guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
			return .file(URL(fileURLWithPath: path))
		default:
			return .system(name)
		}
	}
}

@MainActor
final class FeedbackSoundPlayer: NSObject, NSSoundDelegate {
	static let shared = FeedbackSoundPlayer()

	/// NSSound stops when released, so sounds are held until they finish.
	private var playing: Set<NSSound> = []

	/// Plays the start or stop cue using the saved settings and returns how long it
	/// lasts, or 0 when nothing plays.
	@discardableResult
	func play(start: Bool, defaults: UserDefaults = .standard) -> TimeInterval {
		let settings = FeedbackSoundSettings(defaults: defaults)
		guard let source = settings.source(start: start) else { return 0 }
		return play(source, volume: settings.volume, outputDeviceUID: settings.outputDeviceUID)
	}

	func duration(start: Bool, defaults: UserDefaults = .standard) -> TimeInterval {
		guard let source = FeedbackSoundSettings(defaults: defaults).source(start: start) else { return 0 }
		return makeSound(source)?.duration ?? 0
	}

	@discardableResult
	func play(_ source: FeedbackSoundSource, volume: Double, outputDeviceUID: String) -> TimeInterval {
		guard let sound = makeSound(source) else {
			AppLogger.shared.audioManager.error("Could not load feedback sound: \(String(describing: source))")
			return 0
		}
		sound.volume = Float(min(max(volume, 0), 1))
		if outputDeviceUID != FeedbackSoundSettings.systemOutputUID {
			sound.playbackDeviceIdentifier = outputDeviceUID
		}
		sound.delegate = self
		playing.insert(sound)
		if !sound.play() {
			playing.remove(sound)
			return 0
		}
		return sound.duration
	}

	private func makeSound(_ source: FeedbackSoundSource) -> NSSound? {
		switch source {
		case .system(let name):
			// NSSound(named:) returns a shared instance; copy it so volume and device
			// changes do not leak into other users of the same system sound.
			return NSSound(named: name)?.copy() as? NSSound
		case .file(let url):
			return NSSound(contentsOf: url, byReference: true)
		}
	}

	nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
		MainActor.assumeIsolated {
			_ = playing.remove(sound)
		}
	}

	/// Copies a user-picked sound into Application Support so it keeps working if
	/// the original is moved or deleted.
	static func importCustomSound(from source: URL, start: Bool, directory: URL? = nil) throws -> URL {
		let folder =
			directory
			?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera")
			.appendingPathComponent("Sounds")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

		let ext = source.pathExtension.isEmpty ? "aiff" : source.pathExtension.lowercased()
		let destination = folder.appendingPathComponent("\(start ? "start" : "stop")-\(UUID().uuidString).\(ext)")
		try FileManager.default.copyItem(at: source, to: destination)

		guard NSSound(contentsOf: destination, byReference: true) != nil else {
			try? FileManager.default.removeItem(at: destination)
			throw CocoaError(.fileReadCorruptFile)
		}
		return destination
	}
}
