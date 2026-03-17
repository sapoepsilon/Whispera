---
title: 'Whispera: Privacy-First Voice Transcription and Control for macOS'
tags:
  - Swift
  - macOS
  - speech recognition
  - transcription
  - voice control
  - on-device inference
  - accessibility
  - Apple Silicon
authors:
  - name: Ismatulla Mansurov
    orcid: 0009-0006-9946-8851
    affiliation: 1
affiliations:
  - name: Independent Researcher
    index: 1
date: 10 March 2026
bibliography: paper.bib
---

# Summary

Whispera is a native macOS application that provides on-device speech transcription and voice-driven system control. It replaces the built-in macOS dictation with WhisperKit — running OpenAI's Whisper model on Apple's Neural Engine — delivering higher transcription accuracy while keeping all audio data on the user's machine. Whispera supports live speech-to-text, local audio and video file transcription, YouTube video transcription, and network stream transcription, all processed locally on Apple Silicon. An optional command mode extends the application into a voice control system, converting spoken commands into structured intents mapped to auditable shell templates for hands-free macOS operation.

# Statement of need

Speech transcription is a common need across research and professional workflows: transcribing interviews, lectures, meeting recordings, and media content. Existing tools either route audio to cloud APIs (raising privacy concerns, especially with sensitive recordings [@kairouz2021federated]) or require complex local setup with command-line tools that are inaccessible to non-technical users. The built-in macOS dictation is limited to short-form input and does not support file or URL transcription.

For users with motor or visual impairments, voice-driven interfaces serve as a primary mode of interaction [@pradhan2018accessibility]. macOS Voice Control provides basic accessibility support but lacks extensibility for developer-oriented workflows and does not allow user-defined command mappings.

Whispera addresses both needs in a single application: a privacy-first transcription tool that handles diverse input sources (live speech, files, URLs, streams) with no cloud dependency, and a configurable voice command system for hands-free macOS control. The software serves as a research platform for three active areas of investigation: (1) on-device speech processing, where researchers can study latency, accuracy, and model-size trade-offs on consumer hardware without cloud confounds; (2) privacy-preserving human-computer interaction, where the fully local pipeline provides a controlled environment for studying voice interfaces with zero data exfiltration; and (3) voice-driven accessibility, where the extensible command configuration enables rapid prototyping of custom voice workflows for users with diverse needs.

# State of the field

Cloud transcription services (Otter.ai, Rev, Google Speech-to-Text) offer high accuracy but require uploading audio to external servers, which may be unacceptable for sensitive content such as medical interviews, legal proceedings, or confidential meetings. Local alternatives like Whisper.cpp and whisper-rs provide command-line access to Whisper models but require manual setup and lack a graphical interface or system integration on macOS.

WhisperKit [@whisperkit] brought Whisper inference to Apple's Neural Engine, enabling fast on-device transcription. However, WhisperKit is a framework, not an end-user application — it requires developers to build their own interface around it.

For voice control, Snips [@coucke2018snips] pioneered on-device voice understanding for IoT devices, and Rasa [@bocklisch2017rasa] provides open-source NLU pipelines for chatbot workflows. Neither targets desktop system control or provides a native macOS experience.

Whispera combines WhisperKit-based transcription with a native macOS interface (menu bar app, global shortcuts, accessibility API integration) and adds voice command capabilities through a config-driven template engine. This combination of transcription and control in a single privacy-first application is not available in existing open-source tools.

# Software design

Whispera is a Swift/SwiftUI application built for macOS 13+ on Apple Silicon. It runs as a menu bar application with a global keyboard shortcut for activation.

**Transcription mode** supports four input types:

- **Live speech**: Real-time dictation that types transcribed text directly into the active application, replacing macOS built-in dictation.
- **Local files**: Batch transcription of audio and video files with timestamp output.
- **YouTube URLs**: Automatic download and transcription of YouTube videos.
- **Network streams**: Transcription of streaming audio/video from arbitrary URLs.

All transcription runs on-device via WhisperKit, which executes Whisper models on Apple's Neural Engine. Whispera supports multiple Whisper model sizes and provides multi-language transcription and real-time translation.

**Command mode** activates a pipeline that converts spoken commands into system actions:

1. Speech is transcribed on-device via WhisperKit.
2. The text is preprocessed (typo correction, normalization).
3. An intent parser maps the text to a JSON object with `category`, `operation`, and parameters.
4. The JSON intent is matched against shell command templates in a configuration file (`macos_operations.json`), covering 43 categories and 358 operations.

The intent parser uses a LoRA-adapted language model [@lora] fine-tuned on Apple's MLX framework [@mlx2023]. The JSON intermediate representation acts as a security boundary — the model cannot produce arbitrary shell commands, only intents matching predefined templates.

The software architecture separates concerns across modules: `AudioManager` for recording and streaming, `LiveTranscription` for real-time speech-to-text, `FileTranscription` for file and URL processing, and the command pipeline as an independent path. The codebase includes unit tests, integration tests, and UI tests, with CI via GitHub Actions.

# Research impact statement

Whispera ([github.com/sapoepsilon/Whispera](https://github.com/sapoepsilon/Whispera)) has been in active public development since June 2025, with over 140 GitHub stars, 9 tagged releases, and ongoing community engagement through issues and pull requests. The application provides a reproducible research platform: researchers can benchmark on-device speech recognition across Whisper model sizes, study the accuracy-latency trade-off of local intent parsing, or prototype custom voice-driven accessibility workflows by editing a JSON configuration file. The command mode's training pipeline and evaluation suite — including five baselines, per-category accuracy analysis, ablation studies, and ASR noise robustness analysis — are documented in a companion repository ([whisperaModel](https://github.com/sapoepsilon/whisperaModel)), with model weights and dataset publicly hosted on HuggingFace for reproducibility.

# AI usage disclosure

Claude (Anthropic, versions 3.5 Sonnet and Claude Code) was used during development for:

- **Code assistance**: Refactoring suggestions and boilerplate generation for Swift UI components and test scaffolding, reviewed and modified by the author.
- **Evaluation scripts**: Initial structure for Python evaluation scripts in the companion repository, subsequently validated and extended by the author.
- **Documentation**: Early drafts of README sections and dataset cards, rewritten by the author.

All architectural decisions — application design, transcription pipeline, command mode architecture, template-based execution boundary, module separation — were made by the author. The author reviewed, edited, and validated all AI-assisted outputs.

# Acknowledgements

This work was conducted independently without external funding. Whispera builds on [WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device speech recognition, [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) for content extraction, and [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) for rendering.

# References
