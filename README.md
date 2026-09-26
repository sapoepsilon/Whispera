# Whispera

A native macOS app that replaces the built-in dictation with OpenAI's Whisper for superior transcription accuracy. Transcribe speech, local files, YouTube videos, and network streams - all processed locally on your Neural Engine.
<div align="center">
  
  ### [⬇️ Download Latest Release](https://github.com/sapoepsilon/Whispera/releases/latest/download/Whispera.dmg)
  
  [![GitHub release (latest by date)](https://img.shields.io/github/v/release/sapoepsilon/Whispera?style=for-the-badge&logo=github&color=0969da&labelColor=1f2328)](https://github.com/sapoepsilon/Whispera/releases/latest)
  
</div>

## Install

Download the DMG above, or install with [Homebrew](https://brew.sh):

```bash
brew tap sapoepsilon/whispera https://github.com/sapoepsilon/Whispera
brew install --cask sapoepsilon/whispera/whispera
```

The app keeps itself up to date through Sparkle, so `brew upgrade` is only needed if you turn automatic updates off. `brew uninstall --zap --cask whispera` also removes models, logs and settings.

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

- **Dictation** - Replaces macOS dictation with on-device speech recognition. The transcript is pasted, typed, copied or handed to a script you choose.
- **Live Transcription Mode** (beta, off by default) - Shows text while you speak.
- **File transcription** - Audio and video files, network media URLs and YouTube videos, as plain text or with timestamps.
- **Models** - Any WhisperKit model, your own converted Whisper models, and NVIDIA Parakeet TDT v2 (English) and v3 (25 European languages) through FluidAudio. Choose the compute units (Automatic, Neural Engine, GPU or CPU) and unload an idle model to free memory.
- **Languages** - Choose the spoken language or let Whispera detect it, and translate to English with Whisper models.
- **Recording control** - Toggle, push-to-talk or hold-or-toggle activation, a cancel shortcut (Escape by default), an extra recording buffer so the last word is not cut off, and a microphone that opens per recording, stays open briefly or is always on.
- **Skip Silence** - Voice activity detection (energy based, or the neural Silero model) drops clips with no speech.
- **Text clean-up** - Custom words with fuzzy correction, filler-word removal and Simplified/Traditional Chinese conversion.
- **LLM post-processing** (optional) - Rewrite transcripts with your own prompts through Apple Intelligence on-device (macOS 26) or an OpenAI-compatible provider: OpenAI, Anthropic, OpenRouter, Groq, Cerebras, Z.AI, AWS Bedrock, or a local server such as Ollama or LM Studio. API keys are stored in the Keychain.
- **History** - Recent transcripts, optionally with their audio, with a retention setting. Copy or retry them from the History window.
- **Automation** - A command line on the app binary, `whispera://` links, Shortcuts actions and Raycast script commands.
- **Secure Input handling** - Whispera tells you when another app (a password field, a terminal with secure keyboard entry) blocks the dictation shortcut, keeps a fallback shortcut working, and never keeps text typed into a secure field on the clipboard or in history.
- **Localized** in English, Spanish, German and French.

Transcription runs on your Mac. The internet is only needed to download models, check for updates, and for LLM post-processing when you pick a cloud provider.

## Automation

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

Whispera adds Shortcuts actions to toggle, start, stop and cancel dictation, set the language, copy the last transcript, open history, add a dictionary word and transcribe an audio file. For Raycast, use **Settings > Automation > Raycast script commands** to save the scripts into the folder you added under Raycast > Extensions > Script Commands (the same scripts are in `integrations/raycast/`).

## Related Projects

Voice command research (a Qwen2.5 + LoRA intent parser trained with MLX) lives in [sapoepsilon/whisperaModel](https://github.com/sapoepsilon/whisperaModel), with the [model weights](https://huggingface.co/sapoepsilon/whispera-voice-commands) and [dataset](https://huggingface.co/datasets/sapoepsilon/mac-voice-commands) on Hugging Face. It is not part of this app.

## Roadmap

- [x] Multi-language support beyond English 
  - **PR**: https://github.com/sapoepsilon/Whispera/pull/2
  - **Release**: https://github.com/sapoepsilon/Whispera/releases/tag/v1.0.3
- [x] Real-time translation capabilities
  - **PR**: https://github.com/sapoepsilon/Whispera/pull/17
  - **Release**: https://github.com/sapoepsilon/Whispera/releases/tag/v1.0.18
- [ ] Additional customization options

## Usage

Press your dictation shortcut (Option-Command-R by default) to start, and again to stop; the transcript goes into the focused text field. Drop a file on the menu bar popover, or use Browse, to transcribe it.

## Known Issues

- Intel Macs are not supported (see [Issue 15](https://github.com/sapoepsilon/whispera/issues/15)).
- If the app quits unexpectedly, please report it in [Issue 21](https://github.com/sapoepsilon/whispera/issues/21).

## Requirements

- macOS 14.0 (Sonoma) or later; Apple Intelligence post-processing needs macOS 26
- Apple Silicon
- Building from source needs Xcode 26 (the macOS 26 SDK, for the weakly linked FoundationModels framework)

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
