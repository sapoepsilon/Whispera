# Contributing to Whispera

Thanks for your interest in contributing to Whispera. This document covers the basics.

## Reporting Bugs

Open a [GitHub issue](https://github.com/sapoepsilon/Whispera/issues) with:

- macOS version and Mac model
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs (Settings > Debug > Export Logs)

## Submitting Pull Requests

1. Fork the repo and create a branch from `main`.
2. Make your changes.
3. Run the test suite:
   ```bash
   xcodebuild test -scheme Whispera -project Whispera.xcodeproj
   ```
4. Open a PR against `main` with a clear description of what you changed and why.

## Code Style

- The project uses [swift-format](https://github.com/apple/swift-format) with the config in `.swift-format` at the repo root.
- Use `AppLogger.shared.<category>` for logging instead of `print()` or `os.log`.
- Only add code comments to explain *why*, not *what*.
- Use commitlint-style commit messages (e.g., `feat:`, `fix:`, `docs:`).

## Project Structure

- **macOS app** (this repo): Swift, SwiftUI, WhisperKit. Handles transcription, command mode UI, and system integration.
- **ML training pipeline** ([whisperaModel](https://github.com/sapoepsilon/whisperaModel)): Python, MLX. Handles dataset generation, model fine-tuning, and evaluation for the command mode intent parser.

## Requirements

- macOS 13.0+
- Apple Silicon
- Xcode 15+

## Questions

If something is unclear, open an issue and ask. We're happy to help.
