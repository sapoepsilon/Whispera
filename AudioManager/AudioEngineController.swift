import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum AudioEngineError: Error, LocalizedError {
	case invalidFormat
	case engineNotRunning
	case noInputNode
	case deviceSetupFailed(String)

	var errorDescription: String? {
		switch self {
		case .invalidFormat:
			return "Invalid audio format"
		case .engineNotRunning:
			return "Audio engine is not running"
		case .noInputNode:
			return "No input node available"
		case .deviceSetupFailed(let reason):
			return "Device setup failed: \(reason)"
		}
	}
}

@MainActor
@Observable
final class AudioEngineController {
	private(set) var isRunning = false

	@ObservationIgnored
	private var engine: AVAudioEngine?
	@ObservationIgnored
	private var routeObserver: NSObjectProtocol?
	@ObservationIgnored
	private var isHandlingRouteChange = false

	var onRouteChange: (() async -> Void)?

	var inputNode: AVAudioInputNode? {
		engine?.inputNode
	}

	var inputFormat: AVAudioFormat? {
		engine?.inputNode.outputFormat(forBus: 0)
	}

	// MARK: - Setup

	func setup(deviceID: AudioDeviceID? = nil) async throws -> AVAudioInputNode {
		cleanup()

		let newEngine = AVAudioEngine()
		engine = newEngine

		let inputNode = newEngine.inputNode

		#if os(macOS)
		if let deviceID {
			try setInputDevice(deviceID, on: inputNode)
		}
		#endif

		let hardwareSampleRate = inputNode.inputFormat(forBus: 0).sampleRate
		let outputFormat = inputNode.outputFormat(forBus: 0)

		guard hardwareSampleRate > 0, outputFormat.channelCount > 0 else {
			throw AudioEngineError.invalidFormat
		}

		newEngine.prepare()
		try newEngine.start()

		if let deviceID {
			verifyActiveDevice(expected: deviceID)
		}

		isRunning = true
		setupRouteObserver()

		return inputNode
	}

	private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
		guard let audioUnit = inputNode.audioUnit else {
			throw AudioEngineError.deviceSetupFailed("Could not access audio unit")
		}

		var mutableDeviceID = deviceID
		let status = AudioUnitSetProperty(
			audioUnit,
			kAudioOutputUnitProperty_CurrentDevice,
			kAudioUnitScope_Global,
			0,
			&mutableDeviceID,
			UInt32(MemoryLayout<AudioDeviceID>.size)
		)

		guard status == noErr else {
			throw AudioEngineError.deviceSetupFailed("AudioUnitSetProperty failed with status \(status)")
		}

		let name = getDeviceName(for: deviceID) ?? "unknown"
		AppLogger.shared.deviceManager.info("Set input device to: \(name) (ID: \(deviceID))")
	}

	private func verifyActiveDevice(expected: AudioDeviceID) {
		guard let audioUnit = engine?.inputNode.audioUnit else { return }

		var actualDeviceID: AudioDeviceID = 0
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		let status = AudioUnitGetProperty(
			audioUnit,
			kAudioOutputUnitProperty_CurrentDevice,
			kAudioUnitScope_Global,
			0,
			&actualDeviceID,
			&size
		)

		if status == noErr {
			let name = getDeviceName(for: actualDeviceID) ?? "unknown"
			if actualDeviceID == expected {
				AppLogger.shared.deviceManager.info("Verified active input device: \(name) (ID: \(actualDeviceID))")
			} else {
				let expectedName = getDeviceName(for: expected) ?? "unknown"
				AppLogger.shared.deviceManager.error(
					"Device mismatch — expected: \(expectedName) (ID: \(expected)), actual: \(name) (ID: \(actualDeviceID))")
			}
		}
	}

	private func getDeviceName(for deviceID: AudioDeviceID) -> String? {
		var name: CFString = "" as CFString
		var size = UInt32(MemoryLayout<CFString>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceNameCFString,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
		return status == noErr ? name as String : nil
	}

	// MARK: - Cleanup

	func cleanup() {
		AppLogger.shared.audioManager.debug("🧹 Cleaning up audio engine")

		if let node = engine?.inputNode {
			node.removeTap(onBus: 0)
			AppLogger.shared.audioManager.debug("✅ Tap removed")
		}

		if let engine, engine.isRunning {
			engine.stop()
			AppLogger.shared.audioManager.debug("✅ Engine stopped")
		}

		removeRouteObserver()
		engine = nil
		isRunning = false
	}

	// MARK: - Tap Installation

	func installTap(
		bufferSize: AVAudioFrameCount = 1024,
		handler: @escaping (AVAudioPCMBuffer, AVAudioFormat) -> Void
	) throws {
		guard let node = inputNode else {
			throw AudioEngineError.noInputNode
		}

		guard isRunning else {
			throw AudioEngineError.engineNotRunning
		}

		node.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
			buffer,
			_ in
			handler(buffer, buffer.format)
		}

		AppLogger.shared.audioManager.debug("✅ Microphone tap installed")
	}

	// MARK: - Device Management
	private func getSystemDefaultInputDeviceID() -> AudioDeviceID? {
		var deviceID: AudioDeviceID = 0
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)

		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&address,
			0,
			nil,
			&size,
			&deviceID
		)

		return status == noErr && deviceID != 0 ? deviceID : nil
	}
}

// MARK: - Private Helpers

extension AudioEngineController {
	fileprivate func setupRouteObserver() {
		removeRouteObserver()

		routeObserver = NotificationCenter.default.addObserver(
			forName: .AVAudioEngineConfigurationChange,
			object: engine,
			queue: .main
		) { [weak self] _ in
			guard let self else { return }
			AppLogger.shared.audioManager.debug(
				"🔄 Audio engine configuration changed"
			)

			Task { @MainActor in
				guard !self.isHandlingRouteChange else { return }
				self.isHandlingRouteChange = true
				defer { self.isHandlingRouteChange = false }
				await self.onRouteChange?()
			}
		}
	}

	fileprivate func removeRouteObserver() {
		if let observer = routeObserver {
			NotificationCenter.default.removeObserver(observer)
			routeObserver = nil
		}
	}
}
