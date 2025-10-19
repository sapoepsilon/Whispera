# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Whispera is a native macOS app that replaces built-in dictation with OpenAI's Whisper AI for superior transcription accuracy. The app uses WhisperKit for on-device transcription, supporting both real-time audio recording and file transcription with YouTube support.

## Build & Development Commands

### Building
```bash
xcodebuild -scheme Whispera -project Whispera.xcodeproj build
```

### Testing
```bash
# Run all tests
xcodebuild test -scheme Whispera -project Whispera.xcodeproj

# Run specific test target
xcodebuild test -scheme Whispera -project Whispera.xcodeproj -only-testing:WhisperaTests
xcodebuild test -scheme Whispera -project Whispera.xcodeproj -only-testing:WhisperaUITests
```

### Version Management
```bash
# Bump version (updates both project.pbxproj and Info.plist)
./scripts/bump-version.sh 1.0.5

# Bump and commit
./scripts/bump-version.sh 1.0.5 --commit
```

### Release Distribution
```bash
# Create release build and distribute
./scripts/release-distribute.sh
```

## Architecture

### Core Transcription System
- **WhisperKitTranscriber** (`WhisperKitTranscriber.swift`): Singleton managing WhisperKit integration
  - Model downloading, loading, and switching
  - Live streaming transcription with segment-based confirmation
  - File transcription with timestamps
  - Decoding options persistence in UserDefaults
  - Real WhisperKit transcription (never simulated)

- **AudioManager** (`AudioManager.swift`): Handles audio recording
  - File-based recording (AVAudioRecorder)
  - Streaming recording (AVAudioEngine with 16kHz float buffers)
  - Live transcription mode vs text mode
  - Recording duration tracking

- **FileTranscriptionManager** (`FileTranscription/FileTranscriptionManager.swift`): File transcription
  - Supports audio/video formats (MP3, WAV, MP4, MOV, etc.)
  - Plain text or timestamped transcription
  - Progress tracking with real WhisperKit Progress objects
  - Task cancellation support

### Queue System
- **TranscriptionQueueManager** (`FileTranscription/TranscriptionQueueManager.swift`): Manages transcription queue
  - Serial processing of files
  - Network file downloads via NetworkFileDownloader
  - YouTube downloads via YouTubeTranscriptionManager
  - Auto-deletion of downloaded files (configurable)

### Global Shortcuts
- **GlobalShortcutManager** (`GlobalShortcutManager.swift`): System-wide hotkey handling
  - Text transcription shortcut (default: ⌥⌘R)
  - File selection shortcut (default: ⌃F) for Finder integration
  - Accessibility permissions required
  - Supports file drag-drop, clipboard URLs, and file picker

### UI Components
- **WhisperaApp** (`WhisperaApp.swift`): Main app with AppDelegate
  - Status bar menu integration (accessory mode)
  - Onboarding flow for first launch
  - Single instance enforcement
  - Animated status icons for different states

- **MenuBarView** (`MenuBarView.swift`): Status bar popover UI
- **SettingsView** (`SettingsView.swift`): Comprehensive settings panel
- **OnboardingView** (`Onboarding/`): Multi-step onboarding wizard
- **LiveTranscriptionView** (`LiveTranscription/`): Real-time transcription display

### Logging
- **AppLogger** (`Logger/`): Centralized logging system
  - Category-based loggers (general, audioManager, transcriber, etc.)
  - File-based logging with rotation (10MB limit)
  - Debug/extended logging modes
  - Crash handlers for exception and signal logging
  - Use AppLogger instead of print() or os.log

## Critical Rules

### Transcription
1. **ALWAYS use real WhisperKit transcription** - never implement simulated/fake responses
2. Onboarding test MUST use actual `WhisperKit.transcribe()`
3. If MPS crashes occur, fix the underlying issue rather than simulating

### Code Quality
1. Use `AppLogger.shared.<category>` for logging, not `print()` or `os.log`
2. Only add comments when syntax needs explanation (why, not what)
3. Never skip hooks (`--no-verify`, `--no-gpg-sign`) in git commands
4. Use commitlint format for git commits
5. Never mention Anthropic or Claude Code in commits/PRs

### Settings Storage
- Model settings: `selectedModel`, `lastUsedModel` in UserDefaults
- Decoding options: Persistent via computed properties in WhisperKitTranscriber
- Language: `selectedLanguage` with reactive observation
- Translation: `enableTranslation` flag
- Streaming: `useStreamingTranscription`, `enableStreaming`

### State Management
- WhisperKit state: `.unloaded`, `.loading`, `.loaded`, `.prewarmed`
- Download state: `isDownloadingModel` with NotificationCenter observers
- Recording state: `isRecording`, `isTranscribing` with state change notifications

## Key Dependencies

- **WhisperKit**: Main transcription engine (argmaxinc/WhisperKit @ main)
- **swift-transformers**: Hugging Face transformers (0.1.15)
- **YouTubeKit**: YouTube video downloading (0.2.8)
- **swift-markdown-ui**: Markdown rendering for UI (2.4.1)
- **swift-collections**: Advanced collection types (1.2.1)

## Common Patterns

### Model Operations
Models are downloaded to `~/Library/Application Support/Whispera/models/argmaxinc/whisperkit-coreml/{model-name}/`
- Operations are serialized via `modelOperationTask`
- Download progress tracked via callback
- Models persist across app launches

### Live Transcription
- Segments accumulate with 2-segment buffer for pending text
- Confirmed text appends only new segments (prevents duplication)
- `stableDisplayText` for UI, `pendingText` for internal logic
- Session tracking via `DictationWordTracker`

### Notifications
- `RecordingStateChanged`: Audio recording state
- `DownloadStateChanged`: Model download state
- `WhisperKitModelStateChanged`: Model loading state
- `QueueProcessingStateChanged`: Queue processing
- `fileTranscriptionSuccess/Error`: File transcription results

## Testing Considerations

- Tests should use real WhisperKit when testing transcription
- Mock only external dependencies (network, file system)
- Use `@MainActor` for SwiftUI-related test operations
- Test files located in `WhisperaTests/`, `WhisperaUITests/`
