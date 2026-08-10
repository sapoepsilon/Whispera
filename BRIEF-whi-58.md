# Brief: WHI-58 — generalize the transcription engine, then wire streaming into the app

You are in an **isolated git worktree**. Do not touch any path outside it.

- Worktree: `/Users/uzi/Developer/whispera-worktrees/whi-58`
- Branch: `ismatulla/whi-58-engine-protocol`
- Based on: `ismatulla/whi-50-pill-motion` (`098bf9b`) — **not `main`**

**This is a stacked branch.** `origin/main` has no `Client/` directory at all; the client code exists only on this stack. Do not rebase onto `main`, do not push, do not merge, do not open a PR.

## The two jobs, in order

### 1. WHI-58 — the keystone

Linear WHI-58 is marked Urgent and blocks five other issues. Read it if you can; its substance is below.

`Client/RemoteTranscriber.swift` today holds:

```swift
enum TranscriptionEngine: String, CaseIterable, Sendable {
    case whisperKit
    case whisperViaBYOK
}
struct RemoteTranscriber { func transcribeViaWhispera(...); func transcribeViaBYOK(...) }
```

That is a **switch-based router, not a pluggable interface**. A new engine means editing the enum and every switch over it, and remote and local are separate code paths, so every future capability gets written twice.

Verified facts you can rely on:
- `RemoteTranscriber` has **zero production call sites** — only tests reference it.
- `transcriptionEngine` is **hard-pinned** to `.whisperKit` by a getter that ignores the stored value. The comment says to restore the stored lookup alongside the picker.
- `WhisperKitTranscriber` conforms to **nothing**. `AudioManager` calls it directly — `liveStream()` around line 448, `transcribeAudioArray` around 484, `transcribe` around 508.

Extract **one protocol** — audio in, text out — covering load/unload, model listing and download, file transcription, **streaming**, decoding options, progress reporting and cancellation. Conformers: WhisperKit (local) and a remote one.

**Remote is not a special case.** An HTTP or WebSocket call and an on-device CoreML model are the same shape behind the right interface. Collapsing those paths is the whole point.

**Design the interface against two engines, not one.** An interface written while WhisperKit is the only conformer will encode WhisperKit's assumptions and the second engine will not fit. Sketch both conformers before you finalize the protocol.

**Acceptance, verbatim from the ticket:** `WhisperKitTranscriber` conforms with **no behaviour change**, provable against the existing tests. If behaviour moves, the protocol is wrong.

Mirror the existing pattern rather than inventing a second one: `Client/RecipeRouter.swift` already has a `RecipeExecuting` protocol plus a `@MainActor` router selecting an implementation from settings. That shape is the precedent.

### 2. Wire streaming into the app

The backend and a Swift client package already exist and are proven working.

- Add `whispera-components` as a Swift package dependency, **pinned to the branch `feat/swift-dictation-component`** (it is not merged and has no tag yet). Repo: `https://github.com/sapoepsilon/whispera-components.git`, private, and the build Mac can already fetch it — verified.
- Use its `WhisperaDictation` product for transport. Do not reimplement the socket, the resampling, or the credential handling.
- The remote streaming engine becomes a **conformer of the protocol from job 1**, not a branch beside WhisperKit in `AudioManager`.

**Reuse the existing live UI. Do not build a second one.** `WhisperKitTranscriber` already drives on-screen text through `stableDisplayText`, `pendingText`, `confirmedText` and `shouldShowLiveTranscriptionWindow`, rendered by `LiveTranscription/{LiveTranscriptionView,LiveTranscriptionWindow,DictationView}`. The two-segment confirmation buffer that stops flicker and duplication is already solved there. A remote source must feed **those same properties**. If the remote path grows its own view, the design is wrong.

Settings: no UserDefaults key exists for a custom transcription endpoint. `whisperaServerURL` points at the Whispera backend; `whisperaLocalServerURL` is LLM-only.

## Environment — verified today, do not re-derive

**This Mac has no Xcode.** You cannot build the app here. Build on the other Mac over passwordless SSH:

```
rsync -a --delete --exclude .git --exclude build --exclude .derived \
  /Users/uzi/Developer/whispera-worktrees/whi-58/ \
  ismatullamansurov@192.168.50.89:~/Developer/whispera-worktrees/whi-58-sync/

ssh ismatullamansurov@192.168.50.89 'cd ~/Developer/whispera-worktrees/whi-58-sync && \
  xcodebuild test -scheme Whispera -project Whispera.xcodeproj \
  -only-testing:WhisperaUnitTests/<Suite> -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/test-derived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO'
```

- The DNS name `macbook-pro-5` fails intermittently — **use the IP**.
- Ad-hoc signing avoids a locked-keychain codesign failure. Do not try to sign properly.
- A known pre-existing flake, "Early unexpected exit, never finished bootstrapping", can turn the overall status red while every assertion passed. **Count assertions, not the summary line.**
- `-only-testing:WhisperaUnitTests/AudioManagerLifecycleTests` matches nothing — that file holds suites named `DeviceSwitchRouteTests`, `FailedActivationHealingTests`, `RecordingSegmentLoadingTests`. Filter by suite name.

**A live backend is running for you.** Do not start your own.

- `http://192.168.50.184:3000` — this Mac, reachable from the build Mac (verified HTTP 200).
- Auth: `NODE_ENV=test`, so the bearer token **is** the user id. Use `Bearer demo-user`.
- `GET /transcription/servers` returns the engine, its capabilities, the WebSocket path, and the audio format (`pcm16`, 24000 Hz, mono, base64-json). **Read those from the response; do not hardcode them.**
- Known engine quirk, not your bug: speaches ignores the model query parameter on the realtime path and always transcribes with `faster-distil-whisper-small.en`.

## Constraints

- **Existing tests must pass.** They are the proof that WhisperKit's behaviour did not move.
- Follow repo conventions in `CLAUDE.md`: `AppLogger.shared.<category>` for logging, never `print` or `os.log`; no emojis in code or logs; comments explain why, not what; commitlint commit messages.
- Never mention Anthropic or Claude Code in commits.
- Do not edit anything outside this worktree. Reading the other repos is fine and encouraged — the backend at `/Users/uzi/Developer/whispera-backend-worktrees/realtime-proxy` and the Swift package at `/Users/uzi/Developer/whispera-components-worktrees/dictation` both have a `RESULT.md` worth reading.

## Definition of done

1. One protocol, with WhisperKit and a remote engine both conforming.
2. `WhisperKitTranscriber` behaviour unchanged, proven by the existing suites passing.
3. The app builds on the other Mac.
4. Dictation through the backend reaches the existing live-transcription UI — same properties, no second view.
5. The engine picker question resolved: either restore the stored lookup and expose the picker, or state plainly why you left it pinned.
6. `RESULT.md`: what you built, the protocol's shape, exactly what you ran and what came back, what is unfinished, and any decision you want the owner to confirm.

## Start by

Reading `Client/RemoteTranscriber.swift`, `Client/RecipeRouter.swift`, `WhisperKitTranscriber.swift`, and `AudioManager/AudioManager.swift`. Then sketch **both** conformers in `RESULT.md` before you write the protocol.
