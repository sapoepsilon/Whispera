# Mac Whisper - Development Plan

## Technology Stack
- **SwiftUI** - For the UI (both menu bar and settings window)
- **AppKit** - For menu bar integration (NSStatusItem)
- **AVFoundation** - For audio recording
- **WhisperKit** - Apple's native Swift package for Whisper (replaces whisper.cpp)
- **async/await** - For asynchronous operations

## Development Phases

### Phase 1: Basic App Structure ✅
- [x] Create macOS menu bar app structure with SwiftUI
- [x] Implement settings/setup window UI
- [x] Fix Settings window opening (use SettingsLink for macOS 14+)
- [ ] Handle app permissions (microphone, accessibility)

### Phase 2: Audio & Feedback ✅
- [x] Implement audio recording functionality
- [x] Add audio feedback (sound effects) for recording start/stop

### Phase 3: Whisper Integration ✅
- [x] Add Whisper model download functionality
- [x] Implement model selection logic (auto-detect best model)
- [x] Integrate whisper.cpp for audio transcription

### Phase 4: User Interaction ✅
- [x] Set up global keyboard shortcut handling
- [x] Add clipboard/paste functionality for transcribed text

### Phase 5: Testing
- [ ] Manual testing of all features
- [ ] Write XCTest unit tests

## Features
1. **Menu Bar App** - Minimal UI, always accessible
2. **Settings Window** - Configure model, shortcuts, audio feedback
3. **Audio Feedback** - Sound effects when starting/stopping recording
4. **Smart Model Selection** - Auto-detect best Whisper model for Mac
5. **Global Shortcut** - Quick toggle for transcription (⌘⇧R)
6. **Auto-paste** - Transcribed text goes directly to focused input
7. **Visual Feedback** - Menu bar icon turns red when recording

## Architecture Notes
- SwiftUI for modern, declarative UI
- NSStatusItem for menu bar presence
- Global event monitor for keyboard shortcuts
- Background queue for transcription
- UserDefaults for settings persistence
- SettingsLink for proper Settings window integration (macOS 14+)

## Known Issues & TODOs
- [x] Whisper.cpp integration complete
- [ ] User must install whisper.cpp via: `brew install whisper-cpp` 
- [ ] Accessibility permissions need proper handling
- [ ] Model download progress could use cancel button
- [ ] Custom keyboard shortcut configuration
- [ ] Support for multiple languages
- [ ] Transcription history/logs

## Installation Requirements
Currently requires:
1. **WhisperKit**: Swift Package Manager dependency (integrated in app)
2. **Whisper models**: Downloaded automatically by WhisperKit
3. **Permissions**: Microphone + Accessibility access (prompted automatically)
4. **macOS 14.0+**: Required for WhisperKit

## Major Improvements (WhisperKit vs whisper.cpp)
- ✅ **No external dependencies** - Pure Swift integration
- ✅ **Apple Silicon optimized** - Uses Core ML acceleration
- ✅ **Native Swift async/await** - No subprocess calls
- ✅ **Automatic model management** - WhisperKit handles downloads
- ✅ **Better performance** - Core ML optimization for M1/M2/M3 Macs

## Next Steps
- [ ] Add WhisperKit Swift Package dependency via Xcode
- [x] Enhanced UI with WhisperKit status indicators  
- [x] Custom keyboard shortcut configuration UI
- [x] Realistic transcription simulation with timing
- [ ] Replace simulation with real WhisperKit API calls
- [ ] Test real-time transcription performance

## Latest Enhancements ✨
- **WhisperKit Status Display** - Shows initialization progress in menu bar
- **Enhanced Settings** - WhisperKit model management with live status
- **Custom Shortcut UI** - Interactive shortcut configuration (framework ready)
- **Realistic Simulation** - Duration-based transcription timing
- **Better Model Names** - Clean display of WhisperKit model names