import SwiftUI
import AppKit

struct MenuBarView: View {
	@Bindable var audioManager: AudioManager
	var whisperKit = WhisperKitTranscriber.shared
	@AppStorage("globalShortcut") private var shortcutKey = "⌘⌥D"
	@AppStorage("globalCommandShortcut") private var commandShortcutKey = "⌘⌥C"
	@AppStorage("enableTranslation") private var enableTranslation = false
	@AppStorage("materialStyle") private var materialStyleRaw = MaterialStyle.default.rawValue
	
	@Environment(\.openSettings) private var openSettings
	
	// MARK: - Injected Dependencies
	@State var permissionManager: PermissionManager
	@State var updateManager: UpdateManager
	@Bindable var fileTranscriptionManager: FileTranscriptionManager
	@Bindable var networkDownloader: NetworkFileDownloader
	@Bindable var queueManager: TranscriptionQueueManager
	
	// MARK: - File Drop Handler
	@State private var fileDropHandler: FileDropHandler?
	
	// MARK: - Error/Success Banners
	@State private var errorMessage: String?
	@State private var successMessage: String?
	@State private var dismissErrorTask: Task<Void, Never>?
	@State private var dismissSuccessTask: Task<Void, Never>?
	
	// MARK: - Dynamic Height
	@State private var contentHeight: CGFloat = 550
	
	private var materialStyle: MaterialStyle {
		MaterialStyle(rawValue: materialStyleRaw)
	}
	
	var body: some View {
		VStack(spacing: 0) {
			
			// Main content
			VStack(spacing: 16) {
				// Update notification banner (if available)
				if let latestVersion = updateManager.latestVersion,
				   AppVersion(latestVersion) > AppVersion.current {
					VStack(spacing: 8) {
						HStack {
							Image(systemName: "arrow.down.circle.fill")
								.foregroundColor(.blue)
							Text("Update Available")
								.font(.caption)
								.fontWeight(.medium)
								.foregroundColor(.blue)
							Spacer()
						}
						
						HStack {
							Text("Whispera \(latestVersion)")
								.font(.caption2)
								.foregroundColor(.secondary)
							Spacer()
							if updateManager.isUpdateDownloaded {
								Button("Install") {
									Task {
										try? await updateManager.installDownloadedUpdate()
									}
								}
								.buttonStyle(.bordered)
								.controlSize(.mini)
							} else {
								Button("Update") {
									Task {
										try? await updateManager.downloadUpdate()
									}
								}
								.buttonStyle(.bordered)
								.controlSize(.mini)
							}
						}
					}
					.padding(8)
					.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
					.overlay(
						RoundedRectangle(cornerRadius: 6)
							.stroke(.blue.opacity(0.3), lineWidth: 1)
					)
				}
				
				// Status card
				StatusCardView(
					audioManager: audioManager,
					whisperKit: whisperKit,
					permissionManager: permissionManager,
					fileTranscriptionManager: fileTranscriptionManager,
					networkDownloader: networkDownloader,
					queueManager: queueManager
				)
				
				// Controls
				VStack(spacing: 12) {
					Button(action: {
						audioManager.toggleRecording()
					}) {
						HStack(spacing: 8) {
							Image(systemName: buttonIcon)
							Text(buttonText)
								.font(.system(.body, design: .rounded, weight: .medium))
						}
						.frame(maxWidth: .infinity)
						.frame(height: 40)
					}
					.buttonStyle(PrimaryButtonStyle(isRecording: isActiveState))
					.disabled(audioManager.isTranscribing)
					
					// Shortcut display - design language compliant
					VStack(spacing: 8) {
						HStack {
							Text(enableTranslation ? "Translation" : "Transcription")
								.font(.caption)
								.foregroundColor(.secondary)
							Spacer()
							Text(shortcutKey)
								.font(.system(.caption, design: .monospaced))
								.padding(.horizontal, 8)
								.padding(.vertical, 4)
								.background(Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
								.foregroundColor(.blue)
						}
					}
				}
				
				Divider()
				
				// Secondary actions
				VStack(spacing: 8) {
					if #available(macOS 14.0, *) {
						Button {
							
							
							NSApp.setActivationPolicy(.regular)
							NSApp.activate(ignoringOtherApps: true)
							
							openSettings()
							
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
								if let settingsWindow = NSApp.windows.first(where: {
									$0.title.contains("Settings") ||
									$0.title.contains("Preferences") ||
									$0.title.contains("General") ||
									$0.title.contains("Storage & Downloads") ||
									$0.title.contains("File Transcription") ||
									String(describing: type(of: $0)).contains("Settings") // Might become a problem if we add more windows
								}) {
									settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
									settingsWindow.makeKeyAndOrderFront(nil)
									settingsWindow.orderFrontRegardless()
									NSApp.activate(ignoringOtherApps: true)
								}
							}
						} label: {
							Label("Settings", systemImage: "gear")
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(SecondaryButtonStyle())
					} else {
						Button {
							
							// Set app policy to regular to ensure proper window focus
							NSApp.setActivationPolicy(.regular)
							NSApp.activate(ignoringOtherApps: true)
							
							// Use legacy preferences approach
							NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
							
							// Bring the settings window to front after a brief delay
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
								if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") || $0.title.contains("Preferences") }) {
									settingsWindow.makeKeyAndOrderFront(nil)
									settingsWindow.orderFrontRegardless()
									NSApp.activate(ignoringOtherApps: true)
								}
							}
						} label: {
							Label("Settings", systemImage: "gear")
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(SecondaryButtonStyle())
					}
					
					Button("Quit Whispera") {
						NSApplication.shared.terminate(nil)
					}
					.buttonStyle(TertiaryButtonStyle())
				}
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 20)
			
			// Transcription result
			if let error = audioManager.transcriptionError {
				ErrorBannerView(error: error)
			} else if let transcription = audioManager.lastTranscription {
				TranscriptionResultView(text: transcription)
			}
			
		}
		.background(
			GeometryReader { geometry in
				Color.clear.preference(
					key: ViewHeightKey.self,
					value: geometry.size.height
				)
			}
		)
		.onPreferenceChange(ViewHeightKey.self) { height in
			contentHeight = min(max(height, 400), 700)
		}
		.frame(width: 320, height: contentHeight)
		.background(materialStyle.material)
		.overlay(dropZoneOverlay)
		.overlay(alignment: .bottom) {
			VStack(spacing: 8) {
				if let errorMessage = errorMessage {
					NotificationBanner(message: errorMessage, type: .error)
						.transition(.move(edge: .bottom).combined(with: .opacity))
				}
				if let successMessage = successMessage {
					NotificationBanner(message: successMessage, type: .success)
						.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.padding(.bottom, 8)
			.padding(.horizontal, 8)
			.animation(.spring(response: 0.4, dampingFraction: 0.8), value: errorMessage)
			.animation(.spring(response: 0.4, dampingFraction: 0.8), value: successMessage)
		}
		.onDrop(of: [.fileURL, .text, .plainText], isTargeted: Binding(
			get: { fileDropHandler?.isDragging ?? false },
			set: { isDragging in
				if isDragging {
					fileDropHandler?.dragEntered()
				} else {
					fileDropHandler?.dragExited()
				}
			}
		)) { providers in
			guard let dropHandler = fileDropHandler else { return false }
			
			let info = DropInfo(providers: providers)
			
			// Perform async operation in the background without blocking UI
			Task { @MainActor in
				// Reset drag state immediately to update UI
				dropHandler.dragExited()
				
				// Handle drop in background
				let _ = await dropHandler.handleDrop(info)
			}
			
			// Return true to indicate we can handle the drop
			return dropHandler.canAccept(info)
		}
		.onReceive(NotificationCenter.default.publisher(for: .fileTranscriptionError)) { notification in
			guard let message = notification.userInfo?["message"] as? String else { return }
			showError(message)
		}
		.onReceive(NotificationCenter.default.publisher(for: .fileTranscriptionSuccess)) { notification in
			guard let message = notification.userInfo?["message"] as? String else { return }
			showSuccess(message)
		}
		.onAppear {
			// Initialize file transcription components with queue manager
			fileDropHandler = FileDropHandler(
				fileTranscriptionManager: fileTranscriptionManager,
				networkDownloader: networkDownloader,
				queueManager: queueManager
			)
			
			// WhisperKit initialization is handled by AudioManager
		}
	}
	
	// MARK: - UI Helpers
	
	private var isActiveState: Bool {
		return audioManager.isRecording
	}
	
	private var buttonIcon: String {
		if audioManager.isRecording {
			return "stop.fill"
		} else {
			return "mic.fill"
		}
	}
	
	private var buttonText: String {
		if audioManager.isRecording {
			return "Stop Recording (\(audioManager.formattedRecordingDuration()))"
		} else {
			return "Start Recording"
		}
	}
	
	// MARK: - Drag & Drop UI
	
	@ViewBuilder
	private var dropZoneOverlay: some View {
		if let dropHandler = fileDropHandler, dropHandler.isDragging {
			RoundedRectangle(cornerRadius: 12)
				.fill(dropHandler.dropZoneColor)
				.stroke(dropHandler.isValidDrop ? .green : .red, lineWidth: 2)
				.overlay(
					VStack(spacing: 12) {
						Image(systemName: dropHandler.dropZoneIcon)
							.font(.system(size: 32))
							.foregroundColor(dropHandler.isValidDrop ? .green : .red)
						
						Text(dropHandler.dropZoneText)
							.font(.headline)
							.foregroundColor(dropHandler.isValidDrop ? .green : .red)
							.multilineTextAlignment(.center)
						
						if dropHandler.isValidDrop && dropHandler.draggedItemsCount > 0 {
							Text("\(dropHandler.draggedItemsCount) item\(dropHandler.draggedItemsCount == 1 ? "" : "s")")
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}
				)
				.allowsHitTesting(false)
		}
	}
	
	// MARK: - Notification Handling
	
	private func showError(_ message: String, duration: TimeInterval = 5.0) {
		dismissErrorTask?.cancel()
		
		withAnimation {
			errorMessage = message
		}
		
		dismissErrorTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
			
			guard !Task.isCancelled else { return }
			
			withAnimation {
				errorMessage = nil
			}
		}
	}
	
	private func showSuccess(_ message: String, duration: TimeInterval = 3.0) {
		dismissSuccessTask?.cancel()
		
		withAnimation {
			successMessage = message
		}
		
		dismissSuccessTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
			
			guard !Task.isCancelled else { return }
			
			withAnimation {
				successMessage = nil
			}
		}
	}
}

// MARK: - Status Card
struct StatusCardView: View {
	@Bindable var audioManager: AudioManager
	var whisperKit: WhisperKitTranscriber
	var permissionManager: PermissionManager
	@Bindable var fileTranscriptionManager: FileTranscriptionManager
	@Bindable var networkDownloader: NetworkFileDownloader
	@Bindable var queueManager: TranscriptionQueueManager
	@AppStorage("selectedModel") private var selectedModel = ""
	@AppStorage("selectedLanguage") private var selectedLanguage = Constants.defaultLanguageName
	
	var body: some View {
		VStack(spacing: 12) {
			// Main status section
			HStack(spacing: 12) {
				// Status icon with design language colors
				ZStack {
					Circle()
						.fill(statusColor.opacity(0.2))
						.frame(width: 44, height: 44)
					
					statusIcon
						.font(.system(size: 20))
						.foregroundColor(statusColor)
				}
				
				VStack(alignment: .leading, spacing: 4) {
					Text(statusTitle)
						.font(.system(.headline, design: .rounded))
						.foregroundColor(.primary)
					
					Text(statusSubtitle)
						.font(.caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
			}
			
			// Permission status section
			if permissionManager.needsPermissions {
				HStack {
					HStack(spacing: 6) {
						Circle()
							.fill(.orange)
							.frame(width: 8, height: 8)
						
						Text("Permissions")
							.font(.caption)
							.foregroundColor(.secondary)
					}
					
					Spacer()
					
					Text(permissionManager.missingPermissionsDescription)
						.font(.caption)
						.foregroundColor(.orange)
				}
			}
			
			// AI Model section with current model display
			VStack(spacing: 8) {
				HStack {
					HStack(spacing: 6) {
						Circle()
							.fill(whisperKit.isInitialized ? .green : .orange)
							.frame(width: 8, height: 8)
						
						Text("Whisper Model")
							.font(.caption)
							.foregroundColor(.secondary)
					}
					
					Spacer()
					
					if whisperKit.isInitialized {
						Text("Ready")
							.font(.caption)
							.foregroundColor(.green)
					} else if whisperKit.isInitializing {
						VStack(alignment: .trailing, spacing: 2) {
							HStack(spacing: 4) {
								ProgressView()
									.scaleEffect(0.6)
								Text("Loading...")
									.font(.caption)
									.foregroundColor(.orange)
							}
							
							// Progress bar
							ProgressView(value: whisperKit.initializationProgress)
								.frame(width: 80)
								.scaleEffect(0.8)
							
							// Status text
							Text(whisperKit.initializationStatus)
								.font(.system(.caption2, design: .rounded))
								.foregroundColor(.secondary)
								.lineLimit(1)
								.truncationMode(.tail)
						}
					} else {
						HStack(spacing: 4) {
							ProgressView()
								.scaleEffect(0.6)
							Text("Starting...")
								.font(.caption)
								.foregroundColor(.orange)
						}
					}
				}
				
				// Current model display or download progress
				if whisperKit.isDownloadingModel {
					VStack(spacing: 4) {
						HStack {
							HStack(spacing: 4) {
								ProgressView()
									.scaleEffect(0.5)
								Text("Downloading \(whisperKit.downloadingModelName ?? "model")...")
									.font(.caption)
									.foregroundColor(.orange)
							}
							Spacer()
						}
						
						ProgressView(value: whisperKit.downloadProgress)
							.frame(height: 4)
					}
				} else if whisperKit.isInitialized {
					HStack {
						Text(currentModelDisplayName)
							.font(.system(.caption, design: .rounded, weight: .medium))
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
							.foregroundColor(.blue)
						
						Spacer()
						
						// Translation toggle
						Button(action: {
							audioManager.enableTranslation.toggle()
							print("🟠 StatusCardView - Translation toggled to: \(audioManager.enableTranslation)")
						}) {
							HStack(spacing: 2) {
								Image(systemName: audioManager.enableTranslation ? "arrow.right" : "doc.text")
									.font(.system(size: 8))
								Text(audioManager.enableTranslation ? "\(Constants.languageCode(for: selectedLanguage))" : "TXT")
									.font(.system(.caption2, design: .rounded, weight: .medium))
							}
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(audioManager.enableTranslation ? .orange.opacity(0.2) : .gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
							.foregroundColor(audioManager.enableTranslation ? .orange : .secondary)
						}
						.buttonStyle(.plain)
						
						// Model size indicator
						Text(currentModelSize)
							.font(.system(.caption, design: .monospaced))
							.foregroundColor(.secondary)
					}
				}
			}
			
			// Transcription Queue section - only show if queue has items
			if !queueManager.items.isEmpty {
				VStack(spacing: 8) {
					HStack {
						HStack(spacing: 6) {
							Circle()
								.fill(queueManager.isProcessing ? .blue : .secondary)
								.frame(width: 8, height: 8)
								.animation(.easeInOut(duration: 0.3), value: queueManager.isProcessing)
							
							Text("Transcription Queue")
								.font(.caption)
								.foregroundColor(.secondary)
						}
						
						Spacer()
						
						// Collapse button when expanded
						if queueManager.isExpanded {
							Button(action: {
								withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
									queueManager.toggleExpanded()
								}
							}) {
								Image(systemName: "chevron.up")
									.font(.caption2)
									.foregroundColor(.secondary)
									.rotationEffect(.degrees(queueManager.isExpanded ? 0 : 180))
									.animation(.spring(response: 0.5, dampingFraction: 0.8), value: queueManager.isExpanded)
							}
							.buttonStyle(.plain)
							.help("Collapse queue")
							.transition(.asymmetric(
								insertion: .scale(scale: 0.1).combined(with: .opacity),
								removal: .scale(scale: 0.1).combined(with: .opacity)
							))
							.animation(.spring(response: 0.5, dampingFraction: 0.8), value: queueManager.isExpanded)
						}
						
						// Clear all button
						Button("Clear All") {
							withAnimation(.easeInOut(duration: 0.3)) {
								queueManager.clearAll()
							}
						}
						.buttonStyle(.plain)
						.font(.caption2)
						.foregroundColor(.red)
					}
					
					// Stacked cards view or expanded list with enhanced animations
					if queueManager.isExpanded {
						// Expanded view showing all files
						VStack(spacing: 8) {
							ForEach(queueManager.items, id: \.id) { item in
								QueueListItem(item: item, queueManager: queueManager)
									.transition(.asymmetric(
										insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
										removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.9))
									))
							}
						}
						.padding(8)
						.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
						.frame(maxHeight: 200)
						.transition(.asymmetric(
							insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top)),
							removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top))
						))
						.animation(.spring(response: 0.7, dampingFraction: 0.8), value: queueManager.isExpanded)
					} else {
						// Collapsed stacked cards
						Button(action: {
							withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
								queueManager.toggleExpanded()
							}
						}) {
							ZStack {
								ForEach(Array(queueManager.items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
									QueueStackCard(item: item, queueManager: queueManager)
										.offset(x: CGFloat(index) * 2, y: CGFloat(index) * -3)
										.scaleEffect(1.0 - CGFloat(index) * 0.02)
										.opacity(1.0 - CGFloat(index) * 0.15)
										.zIndex(Double(3 - index))
										.animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(index) * 0.02), value: queueManager.items.count)
								}
								
								// Count badge if more than 3 items
								if queueManager.items.count > 3 {
									VStack {
										HStack {
											Spacer()
											Text("\(queueManager.items.count)")
												.font(.system(.caption2, design: .rounded, weight: .bold))
												.foregroundColor(.white)
												.padding(.horizontal, 6)
												.padding(.vertical, 2)
												.background(.red, in: Capsule())
												.offset(x: -8, y: 8)
												.transition(.asymmetric(
													insertion: .scale(scale: 0.1).combined(with: .opacity),
													removal: .scale(scale: 0.1).combined(with: .opacity)
												))
												.animation(.spring(response: 0.5, dampingFraction: 0.7), value: queueManager.items.count)
										}
										Spacer()
									}
									.zIndex(10)
								}
							}
							.frame(height: 60)
						}
						.buttonStyle(.plain)
						.help("Click to view all files")
						.transition(.asymmetric(
							insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .bottom)),
							removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .bottom))
						))
						.animation(.spring(response: 0.7, dampingFraction: 0.8), value: queueManager.isExpanded)
					}
					
					// Queue controls with smooth animations
					HStack(spacing: 8) {
						if queueManager.isProcessing {
							Button("Cancel All") {
								withAnimation(.easeInOut(duration: 0.3)) {
									queueManager.cancelAll()
								}
							}
							.buttonStyle(.bordered)
							.controlSize(.mini)
							.foregroundColor(.red)
							.transition(.asymmetric(
								insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
								removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.8))
							))
							.animation(.spring(response: 0.5, dampingFraction: 0.8), value: queueManager.isProcessing)
						}
						
						if !queueManager.completedItems.isEmpty {
							Button("Clear Completed") {
								withAnimation(.easeInOut(duration: 0.3)) {
									queueManager.clearCompleted()
								}
							}
							.buttonStyle(.bordered)
							.controlSize(.mini)
							.transition(.asymmetric(
								insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
								removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.8))
							))
							.animation(.spring(response: 0.5, dampingFraction: 0.8), value: queueManager.completedItems.isEmpty)
						}
						
						if !queueManager.failedItems.isEmpty {
							Button("Retry Failed") {
								withAnimation(.easeInOut(duration: 0.3)) {
									queueManager.retryFailed()
								}
							}
							.buttonStyle(.bordered)
							.controlSize(.mini)
							.transition(.asymmetric(
								insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
								removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.8))
							))
							.animation(.spring(response: 0.5, dampingFraction: 0.8), value: queueManager.failedItems.isEmpty)
						}
						
						Spacer()
					}
				}
				.transition(.asymmetric(
					insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top)),
					removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top))
				))
				.animation(.spring(response: 0.7, dampingFraction: 0.8), value: queueManager.items.isEmpty)
			} else {
				// Empty queue hint - drag and drop
				HStack(spacing: 8) {
					Image(systemName: "arrow.down.doc.fill")
						.font(.system(size: 14))
						.foregroundColor(.secondary.opacity(0.6))
					
					Text("Drag files or URLs here to transcribe")
						.font(.caption)
						.foregroundColor(.secondary)
					
					Spacer()
				}
				.padding(12)
				.background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
						.foregroundColor(.secondary.opacity(0.2))
				)
				.transition(.asymmetric(
					insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top)),
					removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top))
				))
				.animation(.spring(response: 0.7, dampingFraction: 0.8), value: queueManager.items.isEmpty)
			}
		}
		.padding(16)
		.background(Color.gray.opacity(0.2).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
	}
	
	private var statusColor: Color {
		return StatusCardView.getStatusColor(
			isRecording: audioManager.isRecording,
			isTranscribing: audioManager.isTranscribing || fileTranscriptionManager.isTranscribing,
			isDownloading: whisperKit.isDownloadingModel || networkDownloader.isDownloading,
			needsPermissions: permissionManager.needsPermissions
		)
	}
	
	private var statusIcon: Image {
		return StatusCardView.getStatusIcon(
			isRecording: audioManager.isRecording,
			isTranscribing: audioManager.isTranscribing || fileTranscriptionManager.isTranscribing,
			isDownloading: whisperKit.isDownloadingModel || networkDownloader.isDownloading,
			needsPermissions: permissionManager.needsPermissions
		)
	}
	
	// MARK: - Reusable Status Functions
	
	static func getStatusColor(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, needsPermissions: Bool = false) -> Color {
		if needsPermissions {
			return .orange
		} else if isDownloading {
			return .orange
		} else if isTranscribing {
			return .blue
		} else if isRecording {
			return .red
		} else {
			return .green
		}
	}
	
	static func getStatusIcon(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, needsPermissions: Bool = false) -> Image {
		if needsPermissions {
			return Image(systemName: "exclamationmark.triangle.fill")
		} else if isDownloading {
			return Image(systemName: "arrow.down.circle.fill")
		} else if isTranscribing {
			return Image(systemName: "waveform")
		} else if isRecording {
			return Image(systemName: "mic.fill")
		} else {
			return Image(systemName: "checkmark.circle.fill")
		}
	}
	
	static func getStatusTitle(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, downloadingModel: String? = nil, enableTranslation: Bool = false, needsPermissions: Bool = false) -> String {
		if needsPermissions {
			return "Permissions Required"
		} else if isDownloading {
			return "Downloading Model..."
		} else if isTranscribing {
			return enableTranslation ? "Translating..." : "Transcribing..."
		} else if isRecording {
			return "Recording..."
		} else {
			return "Ready"
		}
	}
	
	static func getStatusSubtitle(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool = false, downloadingModel: String? = nil, enableTranslation: Bool = false, needsPermissions: Bool = false, recordingDuration: String = "") -> String {
		if needsPermissions {
			return "Grant required permissions to continue"
		} else if isDownloading {
			if let model = downloadingModel {
				let cleanName = model.replacingOccurrences(of: "openai_whisper-", with: "")
				return "Installing \(cleanName) model"
			} else {
				return "Installing Whisper model"
			}
		} else if isTranscribing {
			return enableTranslation ? "Converting speech to English" : "Converting speech to text"
		} else if isRecording {
			return "Recording for \(recordingDuration)"
		} else {
			return "Press shortcut to start recording"
		}
	}
	
	private var statusTitle: String {
		// Prioritize file operations if active
		if networkDownloader.isDownloading {
			return "Downloading File..."
		} else if fileTranscriptionManager.isTranscribing {
			return "Transcribing File..."
		}
		
		return StatusCardView.getStatusTitle(
			isRecording: audioManager.isRecording,
			isTranscribing: audioManager.isTranscribing,
			isDownloading: whisperKit.isDownloadingModel,
			downloadingModel: whisperKit.downloadingModelName,
			enableTranslation: audioManager.enableTranslation,
			needsPermissions: permissionManager.needsPermissions
		)
	}
	
	private var statusSubtitle: String {
		// Prioritize file operations if active
		if networkDownloader.isDownloading {
			let progress = Int(networkDownloader.downloadProgress * 100)
			return "Progress: \(progress)%"
		} else if fileTranscriptionManager.isTranscribing {
			if let filename = fileTranscriptionManager.currentFileName {
				return "Processing: \(filename)"
			}
			return "Processing file..."
		}
		
		return StatusCardView.getStatusSubtitle(
			isRecording: audioManager.isRecording,
			isTranscribing: audioManager.isTranscribing,
			isDownloading: whisperKit.isDownloadingModel,
			downloadingModel: whisperKit.downloadingModelName,
			enableTranslation: audioManager.enableTranslation,
			needsPermissions: permissionManager.needsPermissions,
			recordingDuration: audioManager.formattedRecordingDuration()
		)
	}
	
	private var currentModelDisplayName: String {
		// Always show what WhisperKit is actually using, or fall back to settings
		let modelName = whisperKit.currentModel ?? selectedModel
		if modelName.isEmpty {
			return "No Model"
		}
		let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")
		
		switch cleanName {
			case "tiny.en": return "Tiny (English)"
			case "tiny": return "Tiny (Multilingual)"
			case "base.en": return "Base (English)"
			case "base": return "Base (Multilingual)"
			case "small.en": return "Small (English)"
			case "small": return "Small (Multilingual)"
			case "medium.en": return "Medium (English)"
			case "medium": return "Medium (Multilingual)"
			case "large-v2": return "Large v2"
			case "large-v3": return "Large v3"
			case "large-v3-turbo": return "Large v3 Turbo"
			case "distil-large-v2": return "Distil Large v2"
			case "distil-large-v3": return "Distil Large v3"
			default: return cleanName.capitalized
		}
	}
	
	private var currentModelSize: String {
		// Always show what WhisperKit is actually using, or fall back to settings
		let modelName = whisperKit.currentModel ?? selectedModel
		if modelName.isEmpty {
			return "—"
		}
		let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")
		
		switch cleanName {
			case "tiny.en", "tiny": return "39MB"
			case "base.en", "base": return "74MB"
			case "small.en", "small": return "244MB"
			case "medium.en", "medium": return "769MB"
			case "large-v2", "large-v3": return "1.5GB"
			case "large-v3-turbo": return "809MB"
			case "distil-large-v2", "distil-large-v3": return "756MB"
			default: return "Unknown"
		}
	}
}

// MARK: - Transcription Result
struct TranscriptionResultView: View {
	let text: String
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text("Last Transcription")
					.font(.caption)
					.foregroundColor(.secondary)
				Spacer()
				
				Button {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				} label: {
					Image(systemName: "doc.on.clipboard")
						.font(.caption)
				}
				.buttonStyle(.plain)
				.foregroundColor(.blue)
				.help("Copy to Clipboard")
			}
			
			Text(text)
				.font(.system(.body, design: .rounded))
				.foregroundColor(.primary)
				.lineLimit(4)
				.multilineTextAlignment(.leading)
		}
		.padding(12)
		.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(.blue.opacity(0.3), lineWidth: 1)
		)
		.padding(.horizontal, 20)
		.padding(.bottom, 12)
	}
}


// MARK: - Error Banner
struct ErrorBannerView: View {
	let error: String
	
	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundColor(.red)
			
			Text(error)
				.font(.caption)
				.foregroundColor(.red)
				.lineLimit(2)
			
			Spacer()
		}
		.padding(12)
		.background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(.red.opacity(0.3), lineWidth: 1)
		)
		.padding(.horizontal, 20)
		.padding(.bottom, 12)
	}
}

// MARK: - Button Styles
struct PrimaryButtonStyle: ButtonStyle {
	let isRecording: Bool
	
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.padding(10)
			.font(.system(.body, design: .rounded, weight: .medium))
			.foregroundColor(.white)
			.background(
				RoundedRectangle(cornerRadius: 10)
					.fill(isRecording ? .red : .blue)
					.opacity(configuration.isPressed ? 0.8 : 1.0)
					.scaleEffect(configuration.isPressed ? 0.98 : 1.0)
			)
			.animation(.easeOut(duration: 0.1), value: configuration.isPressed)
	}
}

struct SecondaryButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.padding(10)
			.font(.system(.body, design: .rounded))
			.foregroundColor(.primary)
			.frame(height: 36)
			.background(
				RoundedRectangle(cornerRadius: 8)
					.fill(Color.gray.opacity(0.2))
					.opacity(configuration.isPressed ? 0.7 : 1.0)
					.scaleEffect(configuration.isPressed ? 0.98 : 1.0)
			)
			.animation(.easeOut(duration: 0.1), value: configuration.isPressed)
	}
}

struct TertiaryButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(.caption, design: .rounded))
			.foregroundColor(.secondary)
			.opacity(configuration.isPressed ? 0.7 : 1.0)
			.scaleEffect(configuration.isPressed ? 0.98 : 1.0)
			.animation(.easeOut(duration: 0.1), value: configuration.isPressed)
	}
}

// MARK: - Command Approval View
struct CommandApprovalView: View {
	let command: String
	let userRequest: String
	let onApprove: () -> Void
	let onCancel: () -> Void
	
	var body: some View {
		VStack(spacing: 12) {
			// Header
			HStack(spacing: 8) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundColor(.orange)
				Text("Command Approval Required")
					.font(.headline)
					.foregroundColor(.primary)
				Spacer()
			}
			
			// User request
			if !userRequest.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					Text("Voice Request:")
						.font(.caption)
						.foregroundColor(.secondary)
					Text(userRequest)
						.font(.body)
						.padding(8)
						.background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
				}
			}
			
			// Generated command
			VStack(alignment: .leading, spacing: 4) {
				Text("Generated Command:")
					.font(.caption)
					.foregroundColor(.secondary)
				Text(command)
					.font(.system(.body, design: .monospaced))
					.padding(8)
					.background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
					.textSelection(.enabled)
			}
			
			// Action buttons
			HStack(spacing: 12) {
				Button("Execute") {
					onApprove()
				}
				.buttonStyle(PrimaryButtonStyle(isRecording: false))
				
				Button("Cancel") {
					onCancel()
				}
				.buttonStyle(SecondaryButtonStyle())
			}
		}
		.padding(16)
		.background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.orange.opacity(0.3), lineWidth: 1)
		)
		.padding(.horizontal, 20)
		.padding(.bottom, 12)
	}
}

// MARK: - Clarification View
struct ClarificationView: View {
	let question: String
	let originalRequest: String
	let onSubmit: (String) -> Void
	let onCancel: () -> Void
	
	@State private var response: String = ""
	
	var body: some View {
		VStack(spacing: 12) {
			// Header
			HStack(spacing: 8) {
				Image(systemName: "questionmark.circle.fill")
					.foregroundColor(.blue)
				Text("Clarification Needed")
					.font(.headline)
					.foregroundColor(.primary)
				Spacer()
			}
			
			if !originalRequest.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					Text("Original Request:")
						.font(.caption)
						.foregroundColor(.secondary)
					Text(originalRequest)
						.font(.body)
						.padding(8)
						.background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
				}
			}
			
			VStack(alignment: .leading, spacing: 4) {
				Text("Question:")
					.font(.caption)
					.foregroundColor(.secondary)
				Text(question)
					.font(.body)
					.padding(8)
					.background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
			}
			
			VStack(alignment: .leading, spacing: 4) {
				Text("Your Response:")
					.font(.caption)
					.foregroundColor(.secondary)
				
				TextEditor(text: $response)
					.frame(height: 60)
					.padding(8)
					.background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
					.overlay(
						RoundedRectangle(cornerRadius: 6)
							.stroke(Color.gray.opacity(0.3), lineWidth: 1)
					)
			}
			
			// Action buttons
			HStack(spacing: 12) {
				Button("Submit") {
					onSubmit(response)
					response = ""
				}
				.buttonStyle(PrimaryButtonStyle(isRecording: false))
				.disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				
				Button("Cancel") {
					onCancel()
					response = ""
				}
				.buttonStyle(SecondaryButtonStyle())
			}
		}
		.padding(16)
		.background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.blue.opacity(0.3), lineWidth: 1)
		)
		.padding(.horizontal, 20)
		.padding(.bottom, 12)
	}
}

// MARK: - Queue Stack Card for Status Section

struct QueueStackCard: View {
	@Bindable var item: TranscriptionQueueItem
	let queueManager: TranscriptionQueueManager
	
	var body: some View {
		HStack(spacing: 12) {
			// Status indicator
			ZStack {
				Circle()
					.fill(item.status.color.opacity(0.2))
					.frame(width: 28, height: 28)
				
				Image(systemName: item.status.icon)
					.font(.system(size: 12, weight: .medium))
					.foregroundColor(item.status.color)
			}
			
			VStack(alignment: .leading, spacing: 2) {
				// Display name
				Text(item.displayName)
					.font(.system(.body, design: .rounded, weight: .medium))
					.foregroundColor(.primary)
					.lineLimit(1)
					.truncationMode(.middle)
				
				HStack(spacing: 4) {
					Text(item.status.displayName)
						.font(.caption)
						.foregroundColor(.secondary)
					
					if item.status == .processing {
						Text("• \(Int(item.progress * 100))%")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
			
			Spacer()
			
			// Show in Finder button for completed items (if file was saved)
			if item.status == .completed,
			   let filePath = item.filePath,
			   FileManager.default.fileExists(atPath: filePath) {
				Button(action: {
					NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: URL(fileURLWithPath: filePath).deletingLastPathComponent().path)
				}) {
					Image(systemName: "folder")
						.font(.system(size: 16))
						.foregroundColor(.green)
				}
				.buttonStyle(.plain)
				.help("Show in Finder")
			}
			
			// Cancel/Remove button
			Button(action: {
				if item.status == .failed || item.status == .completed {
					queueManager.removeItem(item)
				} else if item.status == .processing || item.status == .pending {
					queueManager.cancelItem(item)
				}
			}) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 16))
					.foregroundColor(.secondary)
			}
			.buttonStyle(.plain)
			.help(item.status == .completed || item.status == .failed ? "Remove" : "Cancel")
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.secondary.opacity(0.1), lineWidth: 1)
		)
	}
}

// MARK: - Queue List Item for Expanded View

struct QueueListItem: View {
	@Bindable var item: TranscriptionQueueItem
	let queueManager: TranscriptionQueueManager
	
	var body: some View {
		HStack(spacing: 12) {
			// Status indicator
			ZStack {
				Circle()
					.fill(item.status.color.opacity(0.2))
					.frame(width: 20, height: 20)
				
				Image(systemName: item.status.icon)
					.font(.system(size: 10, weight: .medium))
					.foregroundColor(item.status.color)
			}
			
			VStack(alignment: .leading, spacing: 2) {
				// Display name (file title)
				Text(item.displayName)
					.font(.system(.caption, design: .rounded, weight: .medium))
					.foregroundColor(.primary)
					.lineLimit(2)
					.truncationMode(.middle)
				
				HStack(spacing: 4) {
					Text(item.status.displayName)
						.font(.caption2)
						.foregroundColor(.secondary)
					
					if item.status == .processing {
						Text("• \(Int(item.progress * 100))%")
							.font(.caption2)
							.foregroundColor(.secondary)
					}
				}
			}
			
			Spacer()
			
			// Progress indicator for processing items
			if item.status == .processing {
				ZStack {
					Circle()
						.stroke(Color.secondary.opacity(0.2), lineWidth: 2)
						.frame(width: 16, height: 16)
					
					Circle()
						.trim(from: 0, to: item.progress)
						.stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
						.frame(width: 16, height: 16)
						.rotationEffect(.degrees(-90))
						.animation(.easeInOut(duration: 0.3), value: item.progress)
				}
			}
			
			// Show in Finder button for completed items (if file was saved)
			if item.status == .completed,
			   let filePath = item.filePath,
			   FileManager.default.fileExists(atPath: filePath) {
				Button(action: {
					NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: URL(fileURLWithPath: filePath).deletingLastPathComponent().path)
				}) {
					Image(systemName: "folder")
						.font(.system(size: 12))
						.foregroundColor(.green)
				}
				.buttonStyle(.plain)
				.help("Show in Finder")
			}
			
			// Cancel/Remove button
			Button(action: {
				if item.status == .failed || item.status == .completed {
					queueManager.removeItem(item)
				} else if item.status == .processing || item.status == .pending {
					queueManager.cancelItem(item)
				}
			}) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 12))
					.foregroundColor(.secondary.opacity(0.7))
			}
			.buttonStyle(.plain)
			.help(item.status == .completed || item.status == .failed ? "Remove" : "Cancel")
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
		.overlay(
			RoundedRectangle(cornerRadius: 6)
				.stroke(item.status.color.opacity(0.2), lineWidth: 0.5)
		)
	}
}

// MARK: - Notification Banner

enum BannerType {
	case error
	case success
	
	var icon: String {
		switch self {
			case .error: return "exclamationmark.triangle.fill"
			case .success: return "checkmark.circle.fill"
		}
	}
	
	var color: Color {
		switch self {
			case .error: return .red
			case .success: return .green
		}
	}
	
	var backgroundColor: Color {
		switch self {
			case .error: return .red.opacity(0.1)
			case .success: return .green.opacity(0.1)
		}
	}
}

struct NotificationBanner: View {
	let message: String
	let type: BannerType
	
	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: type.icon)
				.font(.system(size: 14))
				.foregroundColor(type.color)
			
			Text(message)
				.font(.caption)
				.foregroundColor(.primary)
				.lineLimit(3)
				.multilineTextAlignment(.leading)
			
			Spacer()
		}
		.padding(12)
		.background(type.backgroundColor, in: RoundedRectangle(cornerRadius: 10))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(type.color.opacity(0.3), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
	}
}

// MARK: - Preference Key for Dynamic Height

struct ViewHeightKey: PreferenceKey {
	static var defaultValue: CGFloat = 550
	
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}
