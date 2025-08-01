# Whispera

A native macOS tool that replaces the built-in dictation with OpenAI's Whisper for superior transcription accuracy.

## Demo: 

https://github.com/user-attachments/assets/1da72bbb-a1cf-46ee-a997-893f1939e626

## Features

- **Enhanced Accuracy**: Leverages WhisperKit for significantly better transcription than macOS dictation
- **Native Integration**: Seamlessly integrates with macOS using global shortcuts
- **Lightweight**: Minimal resource usage while providing powerful transcription capabilities
- **SwiftUI Interface**: Modern, native macOS user experience

## Roadmap

- [x] Multi-language support beyond English 
  - **PR**: https://github.com/sapoepsilon/Whispera/pull/2
  - **Release**: https://github.com/sapoepsilon/Whispera/releases/tag/v1.0.3
- [x] Real-time translation capabilities
  - **PR**: https://github.com/sapoepsilon/Whispera/pull/17
  - **Release**: https://github.com/sapoepsilon/Whispera/releases/tag/v1.0.18
- [ ] Additional customization options

## Usage

Simply use your configured global shortcut to start transcribing with Whisper instead of the default macOS dictation.

## Known Issues

- If the microphone permission page doesn't advance after granting permission, simply go back and forward again to continue.

## Requirements

- macOS 13.0 or later
- Apple Silicon or Intel Mac

## License

MIT License
