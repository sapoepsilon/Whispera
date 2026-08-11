# WHI-58 follow-up: paste-once-at-stop, and a model picker for direct mode

Two independent app-side changes on `ismatulla/whi-58-engine-protocol`. Neither touches
the sibling `WhisperaDictation` package (`../../whispera-components-worktrees/dictation/apple`).

## Change 1 — paste once, when dictation ends

### Current behaviour, as found (before this change)

Reading `AudioManager`, `StreamingTranscriber`, `WhisperKitTranscriber`,
`LiveTranscriptionState` and `DictationWordTracker` turned up a mechanism the task
description didn't name: **the live-typing behaviour was not in `AudioManager.applyAndPaste`
at all.**

- `applyAndPaste` only ever ran for **text mode** (`mode == .text` gated both the
  `dictationProcessor` call and the paste). It was called from
  `transcribeAudioBuffer`/`transcribeAudio`, which only run from the file/streaming
  *text*-mode stop paths. Live mode never called it — so this function was already a
  dead end for live dictation, not the thing doing the incremental pasting.
- The actual incremental-paste mechanism was **`DictationWordTracker.handleConfirmedTextChange`**.
  Both `WhisperKitTranscriber.liveStream()` and `StreamingTranscriber.startStreaming()`
  construct a `DictationWordTracker`, whose `init` wires
  `WhisperKitTranscriber.shared.onConfirmedTextChange` — which proxies to
  `LiveTranscriptionState.shared.onConfirmedTextChange`, the *one* shared singleton
  both engines write into. So every time either engine confirmed a new segment,
  `handleConfirmedTextChange` computed the newly-confirmed words and pasted them
  immediately via a simulated ⌘V — regardless of which engine produced them.
- On stop, `WhisperKitTranscriber.stopLiveStream()` called `confirmPendingText()`
  (flushes the pending tail into `confirmedText`) and `StreamingTranscriber.stopStreaming()`
  awaited `session.finish()` and ingested the final transcript into `confirmedText` —
  but neither pasted anything at that point; the final flush only ever updated the HUD.
  Net effect: the *last* pending words (never yet "confirmed" while speaking) were
  dropped from the paste stream entirely, and nothing was pasted as one whole
  dictation, through the recipe pipeline or otherwise.
- `DictationWordTracker` also carries dead correction-command code
  (`processCorrectionCommand`/`executeCorrection`, "correct that to X", "replace last
  N words") — grepped for call sites; none exist anywhere in the app. It's unwired
  infrastructure that predates this change and is out of scope here.

### What changed

1. **`DictationWordTracker.handleConfirmedTextChange`** no longer pastes. It still
   calls `trackWords` (kept for the dormant correction-command code, harmless either
   way), but the `Task { await pasteText(newContent) }` call is gone. This is the
   actual fix for "no partial ever pastes mid-dictation" — for both engines, since
   the callback is wired through the single shared `LiveTranscriptionState`.

2. **`SpeechTranscribing.stopStreaming()`** changed signature from `() -> Void` to
   `@discardableResult func stopStreaming() async -> String`, returning the finished,
   trimmed transcript instead of relying on a caller re-reading
   `LiveTranscriptionState.shared.confirmedText` after an unspecified delay:
   - `WhisperKitTranscriber+Engine.stopStreaming()` calls the existing
     `stopLiveStream()` (synchronous — it confirms the pending tail before
     returning) and then reads back `LiveTranscriptionState.shared.confirmedText`.
   - `StreamingTranscriber.stopStreaming()` no longer fires-and-forgets a background
     `Task` to `await session.finish()`; it awaits it directly (the method is async
     now) and returns the trimmed result. This removed a nested `Task` — the method
     itself is the async context now.
   - The protocol's default (no-op) implementation returns `""`.

3. **`AudioManager.stopLiveTranscription()`** now does the actual paste-once:
   captures the engine, tears the session down exactly as before, then
   `Task { let transcript = await engine.stopStreaming(); ...; await applyAndPaste(toPaste) }`.
   `isTranscribing` is set `true` for the span of that task so the pill reflects
   "processing" the same way text mode does while its transcription runs.

4. **`AudioManager.applyAndPaste`** dropped the `mode == .text` gates on both the
   `dictationProcessor` call and the paste. It's mode-agnostic now: whichever mode
   produced a final transcript, the recipe pipeline (WHI-41) runs and the result
   (if non-nil and non-empty) pastes once. The two pre-existing text-mode call
   sites (`transcribeAudioBuffer`/`transcribeAudio`) are unaffected in practice —
   `currentRecordingMode` is always `.text` there — this only *adds* a third call
   site (the live-stop path) rather than changing text mode's behaviour.

5. New pure function, unit-tested: `AudioManager.textToPaste(afterLiveDictationFinished:)`
   — trims the transcript and returns `nil` for empty/whitespace-only, non-nil
   otherwise. Tests: `WhisperaUnitTests/LiveDictationPasteTests.swift`.

### Paste decision table (mode × outcome)

| Mode | Outcome | Pastes? | Why |
|---|---|---|---|
| `.text` | transcription succeeds, processor/no-processor produces text | yes, once | unchanged — always did |
| `.text` | processor returns nil (recipe executed an action) | no | unchanged — processor's own contract |
| `.text` | transcription throws | no | error path never reaches `applyAndPaste` |
| `.liveTranscription` | word confirmed mid-dictation | **no (was: yes, per segment)** | `DictationWordTracker` no longer pastes on `onConfirmedTextChange` |
| `.liveTranscription` | user stops, `stopStreaming()` returns non-empty trimmed transcript | **yes, once** (new) | `stopLiveTranscription` → `applyAndPaste` |
| `.liveTranscription` | user stops, transcript is empty/whitespace (nothing said, or a session that never confirmed anything) | no, no error | `textToPaste(afterLiveDictationFinished:)` returns `nil` |
| `.liveTranscription` | user cancels during startup (`cancelCaptureStartup`, before capture is established) | no | this path never calls `stopLiveTranscription`/`stopStreaming` at all |
| `.liveTranscription` | `startStreaming` throws before capture starts | no | `startLiveTranscription`'s catch block sets `isRecording = false` directly, never calls `stopLiveTranscription` |
| `.liveTranscription` | a mid-session failure occurs, then the user explicitly stops | pastes whatever was salvaged (possibly empty → no paste) | consistent with the engine's own existing philosophy ("a failure that arrives with words already in hand ... is the end of a good dictation, not a lost one" — `StreamingTranscriber.report`); an empty result is indistinguishable from "nothing said" and correctly pastes nothing |

The two structural "cancel/error" exclusions (cancelled startup, failed start) never
reach `applyAndPaste` at all, so the single empty-check in `textToPaste` is sufficient
to cover every "must not paste" case in the table without a separate outcome enum.

No new setting was added or needed — no existing paste-on-live-stop toggle was found
in `WhisperaSettings`/`SettingsView` (grepped for `pasteOnLive`, `pasteAtEnd`,
`liveTranscriptionPaste`, etc. — nothing), so paste-once-at-stop simply becomes live
mode's behaviour, as instructed.

## Change 2 — backend model choice in Settings

### `StreamingTranscriber.models()` (direct mode)

Previously returned a single synthetic entry wrapping whatever string was already
saved in `WhisperaSettings.transcriptionDirectModel` — not a real list.

Now: `GET <baseURL>/models` (OpenAI-compatible; `baseURL` already ends in `/v1`,
e.g. `http://192.168.50.140:8000/v1` → `/v1/models`), decodes
`{data: [{id, task, ...}]}`, and filters to `task == "automatic-speech-recognition"`
(a multi-purpose engine host can also serve LLMs/TTS/embeddings under the same
endpoint). `selectModel(_:)` is unchanged — still writes
`WhisperaSettings.transcriptionDirectModel`.

Unreachable/malformed responses throw rather than returning `[]`:
- transport failure or non-2xx → `StreamingTranscriberError.engineUnreachable(host)`
- valid response but no ASR-tasked models → `StreamingTranscriberError.noModelsInstalled(host)`
- undecodable body → `engineUnreachable(host)` (treated the same as unreachable —
  something on the wire is not what was expected)

`StreamingTranscriber` gained an injectable `urlSession: URLSession = .shared`
constructor parameter (mirrors `RemoteTranscriber`'s existing pattern) so this fetch
is testable against `MockURLProtocol` without a real engine. Backend mode
(`whisperaStreaming`) is untouched — it still lists servers via
`DictationServerDirectory.servers()`.

Tests: `WhisperaUnitTests/StreamingTranscriberDirectModelsTests.swift` — filters
non-ASR models out, hits the right path, and turns a 500 / bad JSON / an
all-non-ASR model list into a thrown error rather than silence.

### Settings UI (`SettingsView.swift`, direct-mode section)

The free-text `directEngineModelField` is now the **fallback**, not the only option:

- On first showing the direct-mode section (`.task(id: transcriptionEngineRaw)`) and
  on tapping the new refresh button (⟳, `directEngineModelsRefreshButton`), Whispera
  calls `StreamingTranscriber.direct.models()`.
- **Success** → a `Picker` (`directEngineModelPicker`) bound to `$transcriptionDirectModel`,
  populated with the fetched models, replaces the text field.
- **Failure** → the picker never appears; the free-text field
  (`directEngineModelField`) stays visible with whatever was last saved, plus an
  inline orange warning row with the error's `localizedDescription`
  (e.g. "Could not reach 192.168.50.140 to list its models..."). The saved model
  string is never cleared by a failed fetch.
- State transitions (`isFetchingDirectModels`, the options list, the error row) use
  `.easeInOut(duration: 0.2)`, matching the design language's stated transition
  duration.
- New `@State`: `directModelOptions`, `isFetchingDirectModels`, `directModelFetchError`,
  plus a `refreshDirectModels()` helper that drives them.

## What was run

- Build (remote, per the environment recipe): `xcodebuild ... build` — **BUILD SUCCEEDED**.
- Targeted unit tests (remote): `LiveDictationPasteTests`,
  `StreamingTranscriberDirectModelsTests`, `LiveTranscriptionSegmentBufferTests`,
  `LiveTranscriptionFlickerFilterTests`, `LiveTranscriptionRemoteIngestTests`,
  `TranscriptionRouterTests`, `TranscriptionFailureMessageTests`, `ServerEngineTests`,
  `RecordingWindowPolicyTests`, `DeviceSwitchRouteTests`, `FailedActivationHealingTests`,
  `RecordingSegmentLoadingTests`, `PillAnchorTests`, `SystemAudioMuterTests` — all
  passed (note: the first `xcodebuild test` invocation hit an unrelated codesign
  flake — `errSecInternalComponent` signing `XCTAutomationSupport.framework` with a
  real Developer ID identity despite `CODE_SIGN_IDENTITY=-`; adding
  `CODE_SIGNING_ALLOWED=NO` to the test invocation fixed it and every suite passed
  clean on the retry).
- No microphone on this build/QA Mac (lid shut) — did not attempt the headless
  `WHISPERA_AUTOSTART_DICTATION` launch or install to `/Applications`, per the task's
  "build-check only" instruction.

## What needs the owner's voice QA

- **Live dictation, both engines** (WhisperKit and `whisperaStreaming`/`realtimeDirect`):
  confirm words only ever appear in the live HUD while speaking (never typed into the
  focused app), and the full sentence pastes exactly once, through any matching
  recipe, the moment the shortcut stops the dictation.
- **Silence**: start and immediately stop a live dictation with nothing said —
  confirm nothing pastes and no error/alert appears.
- **Direct-mode model picker** against the real speaches 0.9.0-rc.3 engine at
  `http://192.168.50.140:8000/v1`: confirm the picker lists the installed ASR models,
  selecting one actually changes what the engine transcribes with, and pulling the
  network/pointing at a wrong port produces the fallback text field with a readable
  error rather than a blank picker.
- **Mid-dictation failure then stop** (e.g. kill the engine mid-sentence, then press
  the shortcut): confirm whatever was salvaged pastes once rather than being silently
  dropped, matching the existing "failure with words in hand" philosophy — this path
  could not be exercised without a live engine and microphone.
