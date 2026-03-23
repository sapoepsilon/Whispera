
<div align="right">
  <details>
    <summary >🌐 Language</summary>
    <div>
      <div align="center">
        <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=en">English</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=zh-CN">简体中文</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=zh-TW">繁體中文</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=ja">日本語</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=ko">한국어</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=hi">हिन्दी</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=th">ไทย</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=fr">Français</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=de">Deutsch</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=es">Español</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=it">Italiano</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=ru">Русский</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=pt">Português</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=nl">Nederlands</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=pl">Polski</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=ar">العربية</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=fa">فارسی</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=tr">Türkçe</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=vi">Tiếng Việt</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=id">Bahasa Indonesia</a>
        | <a href="https://openaitx.github.io/view.html?user=sapoepsilon&project=Whispera&lang=as">অসমীয়া</
      </div>
    </div>
  </details>
</div>

# Whispera

A native macOS app that replaces the built-in dictation with OpenAI's Whisper for superior transcription accuracy. Transcribe speech, local files, YouTube videos, and network streams - all processed locally on your Neural Engine.
<div align="center">
  
  ### [⬇️ Download Latest Release](https://github.com/sapoepsilon/Whispera/releases/latest)
  
  [![GitHub release (latest by date)](https://img.shields.io/github/v/release/sapoepsilon/Whispera?style=for-the-badge&logo=github&color=0969da&labelColor=1f2328)](https://github.com/sapoepsilon/Whispera/releases/latest)
  
</div>

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

- **Live transcription** (beta)
- **Speech-to-text** - Replaces macOS native dictation with WhisperKit (OpenAI's Whisper model on Neural Engine) for better accuracy
- **File transcription** - Audio and video files
- **Network media transcription** - Stream video/music URLs
- **YouTube transcription**

All processing runs locally. Internet required only for initial model download.

## Command Mode

Whispera includes a voice-driven command mode for controlling macOS hands-free. Speak a natural-language command and Whispera converts it into a structured JSON intent, which is matched against auditable shell command templates.

**How it works:**

1. Speech is transcribed on-device via WhisperKit
2. The text is parsed by a fine-tuned language model (Qwen2.5-0.5B + LoRA, running locally via MLX)
3. The model outputs a JSON intent (e.g., `{"category": "apps", "operation": "open", "app": "chrome"}`)
4. The intent is matched against templates in `macos_operations.json` and executed

**Example commands:**

| You say | What happens |
|---|---|
| "open chrome" | Launches Google Chrome |
| "mute volume" | Mutes system audio |
| "git status" | Runs `git status` in the current terminal |
| "install numpy" | Runs `pip install numpy` |
| "take a screenshot" | Captures the screen |

The configuration file defines 43 categories and 358 operations covering system control, developer tools (git, npm, docker, homebrew), file management, and network utilities. Add new commands by editing the JSON config — no code changes or retraining needed.

All processing stays on-device. The model cannot execute arbitrary commands; only operations defined in the configuration are allowed.

**Resources:**
- Model weights: [sapoepsilon/whispera-voice-commands](https://huggingface.co/sapoepsilon/whispera-voice-commands) on HuggingFace
- Training and evaluation code: [sapoepsilon/whisperaModel](https://github.com/sapoepsilon/whisperaModel)
- Dataset: [sapoepsilon/mac-voice-commands](https://huggingface.co/datasets/sapoepsilon/mac-voice-commands)

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

- The app does not work with Intel mac(see [Issue 15](https://github.com/sapoepsilon/whispera/issues/15)
- Auto install does not work, after an app has been downloaded, please manually drag and drop the app to you `/Application` folder
- There is a weird issue with app quiting unexpectedly if you get that please report it here: [Issue 21](https://github.com/sapoepsilon/whispera/issues/21)
## Requirements

- macOS 13.0 or later
- Apple Silicon
- We are working on support for Intel Mac

## Credits

Built with:
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - On-device Whisper transcription for Apple Silicon
- [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) - YouTube content extraction
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)


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
