---
title: 'Whispera: A Privacy-First Voice Control System for macOS'
tags:
  - Swift
  - macOS
  - voice control
  - on-device inference
  - accessibility
  - Apple Silicon
  - natural language understanding
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

Whispera is a native macOS application that provides privacy-first voice transcription and voice-driven system control. In its command mode, Whispera converts spoken natural-language commands into structured JSON intents, which are matched against auditable shell command templates defined in a single configuration file. The entire pipeline—speech recognition, intent parsing, and command execution—runs on-device using Apple Silicon, with no data sent to external servers. The configuration currently covers 43 categories and 358 operations spanning system control, developer tools, file management, and network utilities. Users can extend coverage by editing the JSON configuration without modifying application code.

# Statement of need

Voice assistants like Siri, Alexa, and Google Assistant route audio to cloud servers for processing, raising privacy concerns [@kairouz2021federated] and introducing network latency. Users with motor or visual impairments who rely on voice control [@pradhan2018accessibility] are particularly affected by these trade-offs. While macOS includes built-in Voice Control, it lacks extensibility for developer-oriented commands (git, homebrew, docker, npm) and does not allow user-defined command mappings.

Whispera addresses this by providing a fully on-device voice control system with a config-driven architecture. Researchers studying on-device voice interfaces, privacy-preserving interaction, or macOS accessibility can use Whispera as a testbed or extend its command configuration to new domains. Developers building local voice-driven tools can integrate the template engine and intent parser directly.

# State of the field

On-device voice understanding has been explored by Snips [@coucke2018snips], which used lightweight classifiers for IoT devices, and by Apple's on-device trigger detection [@apple2017siri]. Open-source NLU frameworks like Rasa [@bocklisch2017rasa] provide intent classification pipelines but target server-side deployment and chatbot workflows rather than desktop system control.

Whispera differs from these systems in three ways: (1) it is a native macOS application with direct system integration (global shortcuts, accessibility APIs, menu bar interface); (2) it enforces a security boundary by mapping structured intents to auditable shell templates, preventing arbitrary command execution; and (3) its config-driven design lets users add new commands by editing a JSON file rather than writing code or retraining models.

# Software design

Whispera is a Swift application built for macOS 13+ on Apple Silicon. It operates in two modes:

**Transcription mode** replaces macOS built-in dictation with WhisperKit (on-device Whisper inference on the Neural Engine), supporting live speech, local audio/video files, YouTube URLs, and network streams.

**Command mode** activates a four-stage pipeline:

1. **Speech-to-text**: WhisperKit produces text from audio input using the Neural Engine.
2. **Preprocessing**: Typo correction, casual-prefix stripping (e.g., "hey", "please"), and text normalization.
3. **Intent parsing**: A language model maps the preprocessed text to a JSON object containing `category`, `operation`, and operation-specific parameters.
4. **Template mapping and execution**: The JSON intent is matched against shell command templates in `macos_operations.json`. Unrecognized intents are rejected. Parameter values are substituted into fixed templates with quoting to prevent injection.

The JSON intermediate representation creates an auditable boundary: the model cannot produce arbitrary shell commands. Only category/operation pairs defined in the configuration may be executed.

The intent parser uses a LoRA-adapted Qwen2.5-0.5B-Instruct model [@qwen25] fine-tuned on Apple's MLX framework [@mlx2023] with parameter-efficient fine-tuning [@lora]. The adapter adds 8.4 MB of storage. The application also includes runtime robustness features: fuzzy app-name matching, semantic fallback for unrecognized outputs, and confidence scoring that flags low-confidence predictions for user review.

The software architecture separates concerns across distinct modules: `AudioManager` handles recording and streaming, `LiveTranscription` manages real-time speech-to-text, `FileTranscription` handles file and URL processing, and the command pipeline is independent of the transcription path. The codebase includes unit tests, integration tests, and UI tests, with CI via GitHub Actions.

# Research impact statement

Whispera ([github.com/sapoepsilon/Whispera](https://github.com/sapoepsilon/Whispera)) has been in active public development since June 2025, with 147 GitHub stars, 9 tagged releases, and 13 open issues reflecting ongoing community engagement. The command mode architecture, training pipeline, and evaluation suite are documented in a companion repository (`sapoepsilon/whisperaModel`), with model weights and dataset publicly hosted on HuggingFace. The evaluation pipeline includes five baselines, per-category accuracy analysis, ablation studies, and simulated ASR noise robustness analysis, providing a reproducible benchmark for researchers working on on-device voice command systems.

# AI usage disclosure

Claude (Anthropic, versions 3.5 Sonnet and Claude Code) was used during development for:

- **Code assistance**: Refactoring suggestions and boilerplate generation for Swift UI components and test scaffolding, reviewed and modified by the author.
- **Evaluation scripts**: Initial structure for Python evaluation scripts (`eval_models.py`, `ablation_iterations.py`), subsequently validated and extended by the author.
- **Documentation**: Early drafts of README sections and dataset cards, rewritten by the author.

All architectural decisions—command mode pipeline design, JSON intent representation, template-based execution boundary, config-driven extensibility, module separation—were made by the author. All experimental results were produced by the author's code on the author's hardware. The author reviewed, edited, and validated all AI-assisted outputs.

# Acknowledgements

This work was conducted independently without external funding. Whispera builds on [WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device speech recognition.

# References
