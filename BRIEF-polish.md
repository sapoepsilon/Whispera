# Brief: make server and direct transcription reliable, usable, and up to house standard

Both paths already work end to end — proven by driving the real app. This brief is about making them
good enough to ship.

## Where you are

You may edit **two** worktrees, and nothing else:

- App: `/Users/uzi/Developer/whispera-worktrees/whi-58` — branch `ismatulla/whi-58-engine-protocol`
- Package: `/Users/uzi/Developer/whispera-components-worktrees/dictation` — branch `feat/swift-dictation-component`

Commit in both. **Do not push, merge, or open a PR.** Do not touch any other repo or worktree.

## Verified ground truth — do not re-derive

Driving the real signed app produced these, twice each:

```
Streaming through speaches-lan (…); audio pcm16 at 24000 Hz     ← via backend
connecting → listening (29 ms) → finalTranscript("Testing one, two, three.")

Streaming direct to http://192.168.50.140:8000/v1 — no backend  ← direct
connecting → listening (73 ms) → finalTranscript("Testing one, two, three.")
```

Environment, all live right now:
- Backend: `http://127.0.0.1:3000`, started by `run-local.sh` in the backend worktree, tmux `whispera-api`. `NODE_ENV=test`, so the bearer token **is** the user id — use `demo-user`.
- Engine: speaches at `http://192.168.50.140:8000/v1`, model `Systran/faster-distil-whisper-large-v3`.
- Settings keys: `whisperaTranscriptionEngine` (`whisperKit` | `whisperViaBYOK` | `whisperaStreaming` | `realtimeDirect`), `whisperaTranscriptionServerURL`, `whisperaTranscriptionServerId`, `whisperaTranscriptionDirectModel`, `enableStreaming`.
- The app can be driven headlessly: `open -a /Applications/Whispera.app --env WHISPERA_AUTOSTART_DICTATION=<seconds>`. Speech can be injected acoustically with `say`, but **only if `whisperaPauseMediaWhileDictating` is false** — the app mutes system output while dictating, which silences your own test audio. Restore it afterwards.
- No Xcode on this Mac. Build on `192.168.50.89` (use the IP; the DNS name is flaky) via rsync + `xcodebuild … CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`. Known pre-existing flake: "Early unexpected exit, never finished bootstrapping" can turn the summary red while every assertion passed — count assertions.

## 1. Reliability — the two measured failures

### speaches kills the session after one utterance

Both successful runs died ~1.5 s after the first transcript:

```
closed(failed(server(message: "InternalServerError: Internal Server Error")))
```

speaches' own logs show an unhandled `ExceptionGroup` in a Starlette TaskGroup. **It is an engine bug, not ours** — but a dictation that transcribes one phrase and then silently stops is unusable, so the client has to survive it.

Make the session recover: on a *recoverable* server-side close mid-dictation, reconnect and keep capturing, rather than ending the dictation. Audio spoken during the gap is lost — that is acceptable and must be visible in the UI, not hidden. What is not acceptable is the current behaviour, where the user keeps talking to a dead socket with no indication.

Distinguish recoverable from terminal. A rejected credential after the permitted retry, a missing server, and a cancelled session are terminal. A server error, an unexpected close, and a dropped connection are worth one bounded retry with backoff. Do not retry forever, and never retry silently in a way that hides a persistent failure.

### First connect intermittently fails offline

One direct connect failed instantly with `connectionFailed("The Internet connection appears to be offline.")` and the immediate retry succeeded. Treat a first-connect transport failure as retryable, with a short backoff, before surfacing it.

### Where the retry belongs

The package already has a one-shot retry for 4401 in `DictationSession`. Extend that machinery rather than bolting a second retry path into the app — the app should not know how a socket recovers.

## 2. Usability — three real gaps

1. **Direct mode has no settings UI.** `SettingsView` only shows URL and model fields when the engine is `whisperaStreaming`. Selecting "OpenAI-Realtime server (direct)" gives the user no way to say *which* engine or *which* model, so it can only be configured with `defaults write`. Unacceptable for a shipped feature — give it its fields.

2. **Live streaming is off by default.** With a server engine selected but `enableStreaming` false, the app records first and transcribes at the end — which looks like the feature is broken. Either turn it on when the user picks a server engine, or state plainly in the UI that words arrive at the end until they enable it. Pick one and make it obvious.

3. **Connection state is invisible.** `LiveTranscriptionState` already carries `isWaitingForModel` and `waitingForModelStatusText`, and the HUD renders them. Use them: connecting, listening, reconnecting, and failure should each read clearly. A user must never be left talking into a session that is not listening.

Error text must say what to do. "The transcription server did not start listening. Check that it is reachable." is the right register. "InternalServerError" is not.

## 3. UI, UX and animation — follow the house style

`design-language.md` is the source of truth. It is 299 lines; read it. The parts that bind here:

- **Spacing scale**: 4 / 8 / 12 / 16 / 20 / 24 pt. Settings rows are 20 pt horizontal, 16 pt vertical.
- **State transitions**: `.animation(.easeInOut(duration: 0.2), value:)`. Button presses `.easeOut(duration: 0.1)`.
- Match the existing `SettingsSection` and `InfoBox` composition already in `SettingsView.swift` — do not invent a new section style.
- **From `CLAUDE.md`, and it contradicts a tempting shortcut**: use `.alert()` for errors, not an inline `InfoBox`. `InfoBox` is for guidance. Use the `presenting:` data pattern for alerts driven by optional state.
- Respect `prefers-reduced-motion`. Anything that pulses while connecting must settle, not throb indefinitely.
- No emojis in code or log messages. They are allowed only in user-facing strings where deliberately chosen.

## 4. Code cleanliness

- `AppLogger.shared.<category>` only — never `print` or `os.log`.
- Comments explain **why**, not what. Delete any comment that narrates the next line.
- Commitlint commit messages, logical commits, no Anthropic or Claude Code references.
- Tests for the new behaviour: the recoverable-vs-terminal decision deserves a unit test with no network. The package has `DictationChecks` plus a fake engine in `tests/fake-realtime-server.ts`-style Swift form — use them.
- The app's package reference is currently an `XCLocalSwiftPackageReference` with `relativePath = ../../whispera-components-worktrees/dictation/apple`. That only resolves on machines with this exact layout. **Leave it as-is for now** — switching it to the pushed branch is a release step and would break the build rig mid-flight — but note it in `RESULT.md` as required before merge.
- `WHISPERA_AUTOSTART_DICTATION` in `WhisperaApp.swift` is a test affordance. Keep it, but make sure it reads as one and cannot fire in a normal launch.

## Definition of done

1. A dictation survives speaches' post-utterance error and keeps transcribing, or fails with a message that says what happened. Demonstrate it by driving the real app, not by reasoning about the code.
2. Direct mode is fully configurable from Settings — no `defaults write` required.
3. Choosing a server engine leaves the user in a working state, live transcription included.
4. Connection state is legible throughout, and errors are actionable and use `.alert()`.
5. Spacing, motion and composition match `design-language.md`.
6. Builds clean on the build Mac; existing suites still pass; new behaviour has tests.
7. `RESULT.md` in the app worktree: what changed in each repo, exactly what you drove and what came back, what you could not fix and why, and any decision you want the owner to confirm.

## Start by

Reading `design-language.md`, then `Client/StreamingTranscriber.swift`, `Client/TranscriptionRouter.swift`, `Client/LiveTranscriptionState.swift`, the Transcription section of `SettingsView.swift`, and the package's `DictationSession.swift` retry logic. Write your plan into `RESULT.md` before you change behaviour.
