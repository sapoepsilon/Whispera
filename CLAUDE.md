# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Whispera is a native macOS app (macOS 14+, Apple Silicon) that replaces built-in dictation with on-device speech recognition. Whisper models run through WhisperKit and NVIDIA Parakeet models through FluidAudio. It covers dictation into any text field, live transcription, file/URL/YouTube transcription, optional LLM post-processing, transcription history, and automation through a CLI, `whispera://` links, App Intents and Raycast.

## Build & Development Commands

Requires Xcode 26: `OTHER_LDFLAGS` weak-links FoundationModels (Apple Intelligence post-processing), which only the macOS 26 SDK provides.

### Building
```bash
xcodebuild -scheme Whispera -project Whispera.xcodeproj build
```

### Testing
```bash
# Unit tests (what CI runs on pull requests; model-dependent tests skip themselves)
xcodebuild test -scheme Whispera -project Whispera.xcodeproj -only-testing:WhisperaUnitTests

# UI tests
xcodebuild test -scheme Whispera -project Whispera.xcodeproj -only-testing:WhisperaUITests
```

The `WhisperaUnitTests` target compiles the Swift Testing suites in `WhisperaUnitTests/` plus five of the XCTest files in `WhisperaTests/` (`AppLibraryManagerTests`, `AudioDeviceManagerTests`, `LargeModelTranscriptionTests`, `SingleInstanceTests`, `VersionTests`); there is no separate `WhisperaTests` target. The other files in `WhisperaTests/` (`AudioManagerTests`, `FileDropHandlerIntegrationTests`, `ModelSynchronizationTests`, `PermissionManagerTests`, `SimpleTest`, `StreamingTranscriptionIntegrationTests`, `WhisperKitTranscriberTests`) are not in any target's Sources phase and do not build.

### Version Management
```bash
# Bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.pbxproj and Info.plist
./scripts/bump-version.sh 1.0.5

# Bump and commit
./scripts/bump-version.sh 1.0.5 --commit

# Set the build number explicitly, e.g. to match a release
BUILD_NUMBER=36 ./scripts/bump-version.sh 1.3.2 --commit
```

Without `BUILD_NUMBER` the script uses `GITHUB_RUN_NUMBER` on CI and the current build + 1 locally. Keep the tree at the latest released version and build (the appcast's `sparkle:version`, which is the release workflow's run number), or Sparkle offers local builds the release they already are.

### Release Distribution
Releases are cut by pushing a `vX.Y.Z` tag, which runs `.github/workflows/release.yml`: validate the version and bump it on the runner, archive and export with `xcodebuild`, then sign, notarize and package with `scripts/release-distribute-ci.sh` (which also writes the Sparkle-signed `appcast.xml`), write the release body with `scripts/release-notes.sh` (from `release-notes/vX.Y.Z.md` when present; the app shows this body in What's New), publish the GitHub release and commit `appcast.xml` to `main`; a separate `homebrew-cask` job then bumps `Casks/whispera.rb`. See `scripts/README.md`. There is no complete local release script in the repository: `scripts/release-distribute.template.sh` only holds the credential variables of a private, gitignored `release-distribute.sh`; `scripts/README.md` lists the steps to release by hand.

## Architecture

### Entry Point
- `Automation/CLI/WhisperaMain.swift` holds `@main`. It runs the headless CLI (`WhisperaCLI`) when the arguments ask for it and otherwise calls `WhisperaApp.main()`. `WhisperaApp` is not `@main`.

### Project Layout
- `Automation`, `History`, `MiscUI`, `PostProcessing`, `RecordingControl`, `SecureInput`, `TextInsertion`, `TextProcessing`, `WhisperaUnitTests` and `WhisperaUITests` are file-system synchronized groups: new files there join the target automatically.
- Other folders (`AudioManager/`, `ModelEngines/`, `FileTranscription/`, `Onboarding/`, root files, ...) use explicit file references, so new files must be added to `project.pbxproj`.

### Core Transcription System
- **WhisperKitTranscriber** (`WhisperKitTranscriber.swift`): Singleton managing WhisperKit integration
  - Model downloading, loading, and switching
  - Live streaming transcription with segment-based confirmation
  - File transcription with timestamps
  - Decoding options persistence in UserDefaults
  - Real WhisperKit transcription (never simulated)

- **ModelEngines/**: `TranscriptionEngine` abstraction over WhisperKit and `ParakeetEngine` (FluidAudio, Parakeet TDT v2/v3), custom Whisper model import, compute unit preference.

- **AudioManager/**: `AudioManager` handles recording
  - File-based recording (AVAudioRecorder) and streaming recording (AVAudioEngine with 16kHz float buffers)
  - Live transcription mode vs text mode
  - Dictation sessions tracked by `DictationSessionLedger` (RecordingControl) so overlapping capture and transcription stay consistent
  - Device selection and fallback (`AudioDeviceManager`), input channels, feedback sounds, output muting, voice activity trimming

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

### Dictation Pipeline Modules
- **RecordingControl/**: activation modes (toggle, push-to-talk, hold-or-toggle), cancel shortcut, extra recording buffer, mic stream policy, model idle unload, neural (Silero) voice activity detection, shortcut key codes
- **TextProcessing/**: custom word correction, filler-word removal, Chinese script conversion
- **PostProcessing/**: optional LLM rewrite through Apple Intelligence (FoundationModels, macOS 26) or OpenAI-compatible providers; API keys in the Keychain
- **TextInsertion/**: paste, type, copy-only or user script insertion, clipboard restore
- **SecureInput/**: detects Secure Input, keeps a fallback shortcut working, and keeps secure-field text out of the clipboard and history
- **History/**: SwiftData transcription history with optional audio and retention
- **Automation/**: CLI (`CLI/`), `whispera://` URL scheme with a per-install token and App Intents (`RemoteControl/`), Carbon hotkeys (`Hotkeys/`), Raycast script export (`Launchers/`, scripts committed in `integrations/raycast/`)
- **MiscUI/**: theme, app language, notices, What's New, log viewer, recording overlay, `Localizable.xcstrings` and `InfoPlist.xcstrings`

### Global Shortcuts
- **GlobalShortcutManager** (`GlobalShortcutManager.swift`): System-wide hotkey handling
  - Text transcription shortcut (default: ⌥⌘R)
  - File selection shortcut (default: ⌃F) for Finder integration
  - Accessibility permissions required
  - Supports file drag-drop, clipboard URLs, and file picker

### UI Components
- **WhisperaApp** (`WhisperaApp.swift`): Main app with AppDelegate
  - Status bar item: left click opens the popover, right click the status menu (accessory mode)
  - Onboarding flow for first launch
  - Single instance enforcement
  - Animated status icons for different states

- **MenuBarView** (`MenuBarView.swift`): Status bar popover UI (dictate lane, file lane, Fix-It rows, toasts, Activity window); height is measured and applied by `PopoverPresenter`
- **SettingsView** (`SettingsView.swift`): Comprehensive settings panel
- **OnboardingView** (`Onboarding/`): Five-step onboarding (Welcome, Permissions, Setup, Try It, Complete)
- **LiveTranscriptionView** (`LiveTranscription/`): Real-time transcription display

### Updates
- **SoftwareUpdater** (`SoftwareUpdater.swift`): Sparkle is the only updater (appcast `appcast.xml` on `main`). What's New (`MiscUI/WhatsNew.swift`) shows the GitHub release body after an update and fetches it at launch only while Sparkle's automatic checks are on.

### Localization
- UI strings live in `MiscUI/Localizable.xcstrings`, Info.plist strings in `MiscUI/InfoPlist.xcstrings`, shipped in English, Spanish, German and French. Command-line builds do not add new keys to the catalog, so add every new user-facing string with its translations by hand. `LocalizationCatalogTests` fails on a missing translation and `NewStringsLocalizationTests` lists keys that must exist.

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
6. Never use emojis in log messages or code — only allowed in user-facing UI strings where explicitly needed

### UI Patterns
1. Use `.alert()` for error messages, not inline `InfoBox` — alerts are dismissible and don't clutter the layout
2. Use the `presenting:` data pattern for alerts driven by optional state (see Apple docs for `alert(_:isPresented:presenting:actions:message:)`)

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
- **FluidAudio**: Parakeet ASR and Silero VAD on Core ML (Apache-2.0)
- **Sparkle**: Software updates
- **swift-transformers**: Hugging Face transformers (1.1.9)
- **YouTubeKit**: YouTube video downloading (0.4.7)
- **swift-markdown-ui**: Markdown rendering for UI (2.4.1)
- **swift-collections**: Advanced collection types (1.4.0)

Versions are the ones pinned in `Whispera.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (FluidAudio 0.9.1, Sparkle 2.9.0; WhisperKit tracks `main`).

## Common Patterns

### Model Operations
Whisper models are downloaded to `~/Library/Application Support/Whispera/models/argmaxinc/whisperkit-coreml/{model-name}/`. FluidAudio models live under `~/Library/Application Support/Whispera/models/FluidInference/`: `parakeet-tdt-0.6b-v3-coreml/` and `parakeet-tdt-0.6b-v2-coreml/` (`ParakeetEngine`) and `silero-vad-coreml/` (`NeuralVoiceActivityDetector`).
- Downloads, loads and switches are serialized through `ModelOperationQueue` (`modelOperations` in WhisperKitTranscriber); call `runModelOperation` and load with `loadModelInOperation`, never `loadModel` directly
- A dictation that finds the model idle-unloaded reloads it with `ModelOperationQueue.restore`: beside a download that is still in its network phase, otherwise in the queue; operations wait for that reload before loading, so the model the user picked always wins
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
- Test files located in `WhisperaUnitTests/` (Swift Testing), `WhisperaTests/` (XCTest; only the five files listed under Testing are built, into the `WhisperaUnitTests` target) and `WhisperaUITests/`
- Tests that touch `UserDefaults` use `UserDefaults(suiteName:)` with a unique suite name; tests that need a downloaded model gate themselves with `.enabled(if:)`

## Plans Directory

The `plans/` directory contains implementation plans and TDD checklists for features in development. This directory is gitignored and not committed to the repository. Plans are for local development reference only.
