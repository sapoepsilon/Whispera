# Contributing to Whispera

Thanks for your interest in contributing to Whispera. This document covers the basics.

## Reporting Bugs

Open a [GitHub issue](https://github.com/sapoepsilon/Whispera/issues) with:

- macOS version and Mac model
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs: Settings > Storage & Downloads > Application Logs > Show in Finder, or `~/Library/Application Support/Whispera/Logs`. Logs are only written while Extended Logging (same section) is on, which is the default. The live log viewer is the Debug section of the Settings sidebar, which appears after you turn on Debug Mode there.

## Submitting Pull Requests

1. Fork the repo and create a branch from `main`.
2. Make your changes.
3. Run the unit tests (CI runs the same target on every pull request; tests that need a downloaded model skip themselves):
   ```bash
   xcodebuild test -scheme Whispera -project Whispera.xcodeproj -only-testing:WhisperaUnitTests
   ```
4. Open a PR against `main` with a clear description of what you changed and why.

## Code Style

- The project uses [swift-format](https://github.com/apple/swift-format) with the config in `.swift-format` at the repo root.
- Use `AppLogger.shared.<category>` for logging instead of `print()` or `os.log`.
- Only add code comments to explain *why*, not *what*.
- Use commitlint-style commit messages (e.g., `feat:`, `fix:`, `docs:`).

## Project Structure

- **macOS app** (this repo): Swift, SwiftUI, WhisperKit, FluidAudio and Sparkle. Handles transcription, text insertion, post-processing, automation and system integration.
- **Voice command research** ([whisperaModel](https://github.com/sapoepsilon/whisperaModel)): Python, MLX. Dataset generation, fine-tuning and evaluation for a voice command intent parser; not part of the app.

## Requirements

- macOS 14.0+ (Apple Intelligence post-processing needs macOS 26)
- Apple Silicon
- Xcode 26 (the macOS 26 SDK is needed for the weakly linked FoundationModels framework)

## Questions

If something is unclear, open an issue and ask. We're happy to help.
