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

	func setup() async throws -> AVAudioInputNode {
		cleanup()

		let newEngine = AVAudioEngine()
		engine = newEngine
		let input = newEngine.inputNode
		let format = input.inputFormat(forBus: 0)

		guard format.sampleRate > 0, format.channelCount > 0 else {
			throw AudioEngineError.invalidFormat
		}
		showDeviceName()
		try await Task.detached(priority: .userInitiated) {
			try newEngine.start()
		}.value
		isRunning = true
		setupRouteObserver()

		return input
	}

	// TODO: Improve this function
	func showDeviceName() {
		var deviceId = AudioDeviceID(0)
		var deviceSize = UInt32(MemoryLayout.size(ofValue: deviceId))
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var err = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&address,
			0,
			nil,
			&deviceSize,
			&deviceId
		)

		if err == 0 {
			// change the query property and use previously fetched details
			address.mSelector = kAudioDevicePropertyDeviceNameCFString
			var deviceName = "" as CFString
			deviceSize = UInt32(MemoryLayout.size(ofValue: deviceName))
			err = AudioObjectGetPropertyData(
				deviceId,
				&address,
				0,
				nil,
				&deviceSize,
				&deviceName
			)
			if err == 0 {
				AppLogger.shared
					.audioManager.debug(
						"### current default mic:: \(deviceName) "
					)
			} else {
				// TODO:: unable to fetch device name
			}
		} else {
			// TODO:: unable to fetch the default input device
		}
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
