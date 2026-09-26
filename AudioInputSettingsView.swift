import SwiftUI

/// Extra rows for the Microphone section of Settings.
struct AudioInputSettingsRows: View {
	var body: some View {
		InputChannelSettingsRow()
		ClamshellMicrophoneSettingsRow()
		VoiceActivitySettingsRows()
		SettingRow(
			"Mute Audio While Recording",
			description: "Silence your speakers so playback doesn't end up in the transcript"
		) {
			Toggle("", isOn: $muteOutputWhileRecording)
		}
	}

	@AppStorage(SystemOutputMuter.settingKey) private var muteOutputWhileRecording = false
}

struct InputChannelSettingsRow: View {
	@AppStorage(InputChannelSelection.key) private var selectedChannel = InputChannelSelection
		.mixAllChannels
	@AppStorage("selectedAudioInputDeviceUID") private var deviceUID = AudioDeviceManager
		.systemDefaultUID
	@AppStorage(AudioDeviceManager.clamshellDeviceKey) private var clamshellDeviceUID = ""
	@AppStorage("enableStreaming") private var liveTranscriptionEnabled = Constants.enableStreamingDefault
	@AppStorage("useStreamingTranscription") private var useStreamingTranscription = true
	@State private var deviceManager = AudioDeviceManager.shared
	private var transcriber = WhisperKitTranscriber.shared

	private var captureRoute: CaptureRoute {
		CaptureRoute.resolve(
			liveTranscriptionEnabled: liveTranscriptionEnabled,
			modelSupportsLive: transcriber.supportsLiveTranscription,
			useStreamingTranscription: useStreamingTranscription)
	}

	private var channelCount: Int {
		// Re-read when the device list or either saved choice changes
		_ = (deviceManager.availableDevices, deviceUID, clamshellDeviceUID)
		return deviceManager.effectiveInputChannelCount
	}

	var body: some View {
		let count = channelCount
		if count > 1 {
			SettingRow(
				"Input Channel",
				description: InputChannelSelection.settingsDescription(on: captureRoute)
			) {
				Picker("", selection: $selectedChannel) {
					Text("All channels").tag(InputChannelSelection.mixAllChannels)
					ForEach(1...count, id: \.self) { channel in
						Text("Channel \(channel)").tag(channel)
					}
				}
				.labelsHidden()
				.frame(width: 140)
			}
		}
	}
}

struct ClamshellMicrophoneSettingsRow: View {
	@AppStorage(AudioDeviceManager.clamshellDeviceKey) private var clamshellDeviceUID = ""
	@State private var deviceManager = AudioDeviceManager.shared
	private let hasLid = ClamshellDetector.hasLid

	var body: some View {
		if hasLid {
			SettingRow(
				"Microphone When Lid Is Closed",
				description: "Use a different microphone while your Mac runs in clamshell mode"
			) {
				Picker("", selection: $clamshellDeviceUID) {
					Text("Same as above").tag("")
					ForEach(deviceManager.availableDevices) { device in
						Label(device.name, systemImage: device.iconName).tag(device.uid)
					}
				}
				.labelsHidden()
				.frame(maxWidth: 200)
			}
		}
	}
}

struct VoiceActivitySettingsRows: View {
	@AppStorage(VoiceActivitySettings.enabledKey) private var vadEnabled = VoiceActivitySettings
		.defaultEnabled
	@AppStorage(VoiceActivitySettings.sensitivityKey) private var vadSensitivity = VoiceActivitySettings
		.defaultSensitivity.rawValue
	@AppStorage(VADEngine.defaultsKey) private var vadEngine = VADEngine.defaultValue.rawValue

	var body: some View {
		SettingRow(
			"Skip Silence",
			description:
				"Skip clips with no speech and trim silence from them; in Live Transcription Mode, pause transcribing while you are silent. A skipped clip shows \"No speech detected\" in the menu bar. On by default for new installs; left off when updating from a version without it."
		) {
			Toggle("", isOn: $vadEnabled)
		}

		if vadEnabled {
			SettingRow(
				"Speech Detection",
				description:
					"Neural uses the Silero model (downloaded once, about 1 MB) for recorded clips and is better at ignoring noise; Live Transcription Mode always uses Energy"
			) {
				Picker("", selection: $vadEngine) {
					ForEach(VADEngine.allCases) { engine in
						Text(engine.displayName).tag(engine.rawValue)
					}
				}
				.labelsHidden()
				.frame(width: 150)
				.onChange(of: vadEngine) { _, newValue in
					guard newValue == VADEngine.neural.rawValue else { return }
					// Fetch the model now so the first dictation does not wait for the download
					Task.detached(priority: .utility) {
						do {
							try await NeuralVoiceActivityDetector.shared.prepare()
						} catch {
							AppLogger.shared.audioManager.error("Could not prepare the neural VAD model: \(error)")
						}
					}
				}
			}

			SettingRow(
				"Speech Sensitivity",
				description: "Raise it if quiet speech gets skipped; lower it in noisy rooms"
			) {
				Picker("", selection: $vadSensitivity) {
					ForEach(VADSensitivity.allCases) { level in
						Text(level.displayName).tag(level.rawValue)
					}
				}
				.labelsHidden()
				.frame(width: 120)
			}
		}
	}
}

/// Extra rows under the start/stop sound pickers in Settings.
struct FeedbackSoundSettingsRows: View {
	@AppStorage(FeedbackSoundSettings.startSoundKey) private var startSound = "Tink"
	@AppStorage(FeedbackSoundSettings.stopSoundKey) private var stopSound = "Pop"
	@AppStorage(FeedbackSoundSettings.volumeKey) private var volume = FeedbackSoundSettings.defaultVolume
	@AppStorage(FeedbackSoundSettings.outputDeviceKey) private var outputDeviceUID = FeedbackSoundSettings
		.systemOutputUID
	@AppStorage(FeedbackSoundSettings.customStartPathKey) private var customStartPath = ""
	@AppStorage(FeedbackSoundSettings.customStopPathKey) private var customStopPath = ""
	@State private var outputDevices: [AudioOutputDevice] = []
	@State private var importError: String?

	var body: some View {
		if startSound == FeedbackSoundSettings.customSoundName {
			customSoundRow(start: true)
		}
		if stopSound == FeedbackSoundSettings.customSoundName {
			customSoundRow(start: false)
		}

		SettingRow("Sound Volume") {
			Slider(value: $volume, in: 0...1) { editing in
				if !editing { FeedbackSoundPlayer.shared.play(start: true) }
			}
			.frame(width: 180)
		}

		SettingRow("Sound Output", description: "Where start and stop sounds play") {
			Picker("", selection: $outputDeviceUID) {
				Text("System Output").tag(FeedbackSoundSettings.systemOutputUID)
				ForEach(outputDevices) { device in
					Text(device.name).tag(device.uid)
				}
				if outputDeviceUID != FeedbackSoundSettings.systemOutputUID,
					!outputDevices.contains(where: { $0.uid == outputDeviceUID })
				{
					Text("Unavailable device").tag(outputDeviceUID)
				}
			}
			.labelsHidden()
			.frame(width: 180)
			.onChange(of: outputDeviceUID) {
				FeedbackSoundPlayer.shared.play(start: true)
			}
		}
		.onAppear { outputDevices = AudioOutputDeviceCatalog.outputDevices() }
		.onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in
			outputDevices = AudioOutputDeviceCatalog.outputDevices()
		}
		.alert(
			"Couldn't Use Sound File",
			isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } }),
			presenting: importError
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
	}

	private func customSoundRow(start: Bool) -> some View {
		let path = start ? customStartPath : customStopPath
		return SettingRow(
			start ? "Custom Start Sound" : "Custom Stop Sound",
			description: path.isEmpty
				? String(localized: "No file chosen") : URL(fileURLWithPath: path).lastPathComponent,
			descriptionIsVerbatim: true
		) {
			Button("Choose File...") { chooseSound(start: start) }
				.buttonStyle(.bordered)
		}
	}

	private func chooseSound(start: Bool) {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.audio]
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		guard panel.runModal() == .OK, let url = panel.url else { return }

		do {
			let imported = try FeedbackSoundPlayer.replaceCustomSound(
				from: url, start: start, keeping: start ? customStopPath : customStartPath)
			if start { customStartPath = imported.path } else { customStopPath = imported.path }
			FeedbackSoundPlayer.shared.play(start: start)
		} catch {
			AppLogger.shared.audioManager.error("Failed to import custom sound: \(error)")
			importError = String(localized: "\(url.lastPathComponent) could not be played as a sound.")
		}
	}
}
