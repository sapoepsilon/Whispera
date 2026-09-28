# Whispera

A native macOS menu bar app that replaces the built-in dictation with on-device speech recognition: OpenAI's Whisper through WhisperKit, or NVIDIA Parakeet through FluidAudio. Dictate into any text field, or transcribe audio and video files, media URLs and YouTube videos. Transcription runs on your Mac.
<div align="center">
  
  ### [⬇️ Download Latest Release](https://github.com/sapoepsilon/Whispera/releases/latest/download/Whispera.dmg)
  
  [![GitHub release (latest by date)](https://img.shields.io/github/v/release/sapoepsilon/Whispera?style=for-the-badge&logo=github&color=0969da&labelColor=1f2328)](https://github.com/sapoepsilon/Whispera/releases/latest)
  
</div>

## Install

Download the DMG above (or from [Releases](https://github.com/sapoepsilon/Whispera/releases/latest)), or install with [Homebrew](https://brew.sh):

```bash
brew tap sapoepsilon/whispera https://github.com/sapoepsilon/Whispera
brew install --cask sapoepsilon/whispera/whispera
```

The app keeps itself up to date through Sparkle, so `brew upgrade` is only needed if you turn automatic updates off. `brew uninstall --zap --cask whispera` also removes models, logs and settings.

Requires macOS 14 (Sonoma) or later on Apple Silicon. Intel Macs are not supported (see [Issue 15](https://github.com/sapoepsilon/Whispera/issues/15)).

## Quick start

1. Open Whispera; the microphone icon appears in the menu bar and onboarding starts.
2. Grant **Microphone** and **Accessibility** access (Accessibility lets Whispera paste into other apps).
3. Pick a model and let it download.
4. Click into any text field, press **Option-Command-R**, speak, and press it again. The transcript is inserted where your cursor is.

To transcribe a file, drop it on the menu bar popover or use Browse.

## Demos

<table>
  <tr>
    <th>Speech to Text Field</th>
    <th>File/URL Transcription with Timestamps</th>
  </tr>
  <tr>
    <td width="50%">
      <video src="https://github.com/user-attachments/assets/1da72bbb-a1cf-46ee-a997-893f1939e626" controls>
        Your browser does not support the video tag.
      </video>
    </td>
    <td width="50%">
      <video src="https://github.com/user-attachments/assets/d573bef4-a3b2-49ac-a1fd-3c6735648fdc" controls>
        Your browser does not support the video tag.
      </video>
    </td>
  </tr>
</table>

## Features

### Models

- Any WhisperKit model, or NVIDIA Parakeet TDT v2 (English) and v3 (25 European languages) through FluidAudio.
- Import your own converted Whisper models from Hugging Face or a local folder.
- Choose the accelerator: Automatic, Neural Engine, GPU or CPU.
- Unload an idle model after a timeout (immediately up to an hour) or on demand to free memory; it loads again when you dictate.

### Dictation control

- Toggle, push-to-talk, or hold-or-toggle (a tap toggles, a longer hold records until release).
- The shortcut can be a key combination or a single modifier key: Right Command, Right Option, Right Control, Right Shift or Fn.
- Cancel a recording with Escape (rebindable; only active while recording) or the cancel button on the recording pill.
- A short extra recording buffer after you stop, so the last word is not cut off.
- The microphone can open per recording, stay open briefly, or stay always on.

### Accuracy and language

- Custom words with fuzzy correction and decoder bias, so names and jargon come out right.
- Filler-word removal ("um", "uh" and your own list).
- Pick the spoken language or let Whispera detect it; translate to English with Whisper models.
- Simplified/Traditional Chinese conversion.
- Skip Silence: voice activity detection (energy based, or the neural Silero model) drops clips with no speech.

### Text insertion

- Paste (Cmd-V, the default) with your previous clipboard restored, type the characters, copy to the clipboard only, or hand the text to a script you approved.
- Optionally add a trailing space or press Return after inserting.
- Adjustable paste delays for apps that need more time.

### Post-processing (optional, off by default)

- Rewrite transcripts with your own prompts through an LLM: OpenAI, Anthropic, OpenRouter, Groq, Cerebras, Z.AI, AWS Bedrock (Mantle), Apple Intelligence on-device (macOS 26), LM Studio, Ollama, or any OpenAI-compatible server.
- Has its own shortcut (Option-Shift-Space by default), so you choose per dictation whether to clean up the text.
- API keys are stored in the Keychain. Plain `http://` is only allowed for servers on this Mac or your local network.

### History

- Searchable history with the original and post-processed text side by side.
- Star, retry, re-run post-processing, copy or delete entries.
- Keep the latest entries, 3 days, 2 weeks, 3 months, or forever. History is on by default; saving the audio of each dictation is off by default.
- History and Copy Last buttons in the menu bar popover.

### File transcription

- Audio and video files (MP3, WAV, M4A, MP4, MOV and more), network media URLs and YouTube videos.
- A queue for several files, with plain text or timestamped output.

### Interface

- Settings with a sidebar: General, Text Insertion, Storage & Downloads, File Transcription, History, Benchmark and Post-Processing.
- A recording pill (or none) at the top or bottom of the screen, and a screen-edge Recording Glow (on by default) in the color you pick.
- Light, Dark or System appearance, and an option to hide the menu bar icon (open Whispera again to bring it back until its menu closes).
- What's New after each update.
- Localized in English, Spanish, German and French.

## Privacy and security

- Speech is transcribed on your Mac. The network is only used to download models, check for updates (Sparkle), and for post-processing when you pick a cloud provider.
- Secure Input handling: Whispera tells you when a password field or another app blocks the dictation shortcut, keeps a fallback shortcut working, and never keeps text typed into a secure field on the clipboard or in history.
- Script insertion only runs a script you approved in Settings; if it changes, it has to be approved again.

## Advanced

### Debug Mode

Automation, Live Transcription and Debug (a live log viewer) are hidden from the Settings sidebar unless Debug Mode is on. Open Settings and press **Shift-Command-D**, or turn on **Debug Mode** under Settings > Storage & Downloads (shown while Extended Logging is on). Live Transcription Mode is not supported in this release.

### Local LLM servers

For post-processing with a local model, pick **LM Studio** (`http://localhost:1234/v1`) or **Ollama** (`http://localhost:11434/v1`) under Settings > Post-Processing, or **Custom (OpenAI-compatible)** for another server. Local servers need no API key.

### Command line

The app binary doubles as a CLI. Headless transcription uses models already downloaded in the app:

```bash
WHISPERA=/Applications/Whispera.app/Contents/MacOS/Whispera
$WHISPERA --transcribe-file meeting.m4a --model openai_whisper-small --json
$WHISPERA --list-models
$WHISPERA --toggle            # start or stop dictation in the running app
$WHISPERA --help
```

The control flags (`--toggle`, `--toggle-post-process`, `--start`, `--copy-last`, `--open-history`, `--add-word`) are sent to the running app as `whispera://` links, so they fail with "Remote control is off" until you turn on **Settings > Automation > Allow whispera:// links**. `--stop` and `--cancel` work either way.

### `whispera://` links

Links are off until you turn on **Settings > Automation > Allow whispera:// links**, because any web page or app can open a URL. Commands that start recording or read your data (`toggle`, `toggle-post-process`, `start`, `language`, `model`, `copy-last`, `history`, `add-word`) must also carry the per-install token stored in `~/Library/Application Support/Whispera/remote-control-token`.

`stop` and `cancel` are the exception: they need no token and work even while links are off, because they can only end a dictation you already started. Any page or app that can open a URL can therefore stop a dictation (the text heard so far is pasted) or cancel it (the text is discarded), but cannot start one or read anything.

```text
whispera://toggle?token=<token>
whispera://start?token=<token>
whispera://stop
whispera://cancel
whispera://language?name=german&token=<token>
whispera://model?name=openai_whisper-small&token=<token>
whispera://copy-last?token=<token>
whispera://history?token=<token>
whispera://add-word?word=Whispera&token=<token>
```

The CLI control flags and the Raycast scripts read the token for you.

### Shortcuts and Raycast

Whispera adds Shortcuts actions to toggle, start, stop and cancel dictation, set the language, copy the last transcript, open history, add a dictionary word and transcribe an audio file. For Raycast, use **Settings > Automation > Raycast script commands** to save the scripts into the folder you added under Raycast > Extensions > Script Commands (the same scripts are in [`integrations/raycast/`](integrations/raycast/)).

### Insertion scripts

With **Settings > Text Insertion > Insert Text By** set to a script, Whispera hands each transcript to an executable you choose there:

- The transcript arrives on standard input and in `WHISPERA_TRANSCRIPT`, never in the arguments.
- Whispera runs a private copy of exactly the bytes you approved, so `$0` is that copy. The script starts in its own folder, `WHISPERA_SCRIPT_PATH` holds the original path, and `WHISPERA_SCRIPT_DIR` holds its folder. Use `"$WHISPERA_SCRIPT_DIR"` instead of `$(dirname "$0")` to find files next to the script.
- The approval covers the script's path, owner and contents. Editing the script means choosing it again. Changing its permissions, tags or other metadata does not. The script and its folder must not be writable by other users.
- If the script changed or was never approved, it doesn't run. The transcript goes to the clipboard and the menu bar tells you to choose the script again.
- Scripts get a minimal environment and 10 seconds to finish.

## Build from source

Building needs Xcode 26 (the macOS 26 SDK, for the weakly linked FoundationModels framework used by Apple Intelligence post-processing). The app itself runs on macOS 14 and later.

```bash
xcodebuild -scheme Whispera -project Whispera.xcodeproj build
xcodebuild test -scheme Whispera -project Whispera.xcodeproj -only-testing:WhisperaUnitTests
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for pull requests and [scripts/README.md](scripts/README.md) for the release flow.

## Reporting issues

Open a [GitHub issue](https://github.com/sapoepsilon/Whispera/issues) with your macOS version, Mac model, steps to reproduce and logs (Settings > Storage & Downloads > Application Logs > Show in Finder). See [CONTRIBUTING.md](CONTRIBUTING.md#reporting-bugs) for details.

## Related Projects

Voice command research (a Qwen2.5 + LoRA intent parser trained with MLX) lives in [sapoepsilon/whisperaModel](https://github.com/sapoepsilon/whisperaModel), with the [model weights](https://huggingface.co/sapoepsilon/whispera-voice-commands) and [dataset](https://huggingface.co/datasets/sapoepsilon/mac-voice-commands) on Hugging Face. It is not part of this app.

## Credits

Built with:
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - On-device Whisper transcription for Apple Silicon
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) - Parakeet speech recognition and Silero voice activity detection on Core ML
- [Sparkle](https://github.com/sparkle-project/Sparkle) - Software updates
- [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) - YouTube content extraction
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)

Models downloaded at runtime:
- [NVIDIA Parakeet TDT 0.6B v2 and v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), licensed under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/), used through FluidInference's Core ML conversions
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT)
- OpenAI Whisper models (MIT) converted by Argmax for WhisperKit

The post-processing prompt, the provider list and several dictation behaviours are adapted from [Handy](https://github.com/cjpais/Handy) (MIT License).

Thanks to these projects for making privacy-focused, local transcription a reality.

## Citing

If you use Whispera in your research, please cite it:

```bibtex
@software{mansurov2025whispera,
  author = {Mansurov, Ismatulla},
  title = {Whispera},
  year = {2025},
  url = {https://github.com/sapoepsilon/Whispera}
}
```

## License

MIT License — see [LICENSE](LICENSE) for details.
