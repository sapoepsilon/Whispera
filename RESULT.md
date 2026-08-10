# WHI-58 — one transcription protocol, plus a streaming remote engine

Branch `ismatulla/whi-58-engine-protocol`, based on `098bf9b`. Commit `2966c37`.
Not pushed, not merged, no PR.

## What I built

**The protocol** — `Client/SpeechTranscribing.swift`. Audio in, text out.
`TranscriptionEngine` stays an enum but is now identity only; what an engine can
do is `TranscriptionCapabilities` on the conformer, so a new engine adds a case
in exactly one `switch` (the router) instead of every caller.

```swift
@MainActor
protocol SpeechTranscribing: AnyObject {
    nonisolated var engine: TranscriptionEngine { get }
    nonisolated var capabilities: TranscriptionCapabilities { get }
    var state: TranscriptionEngineState { get }          // .unavailable(why) / .preparing(progress,status) / .ready
    func prepare() async throws
    func shutdown()

    var activeModel: String? { get }
    func models() async throws -> [TranscriptionModelInfo]
    func selectModel(_ id: String) async throws
    func downloadModel(_ id: String) async throws
    func cancelModelDownload()

    func transcribe(fileAt: URL, options: TranscriptionOptions) async throws -> String
    func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String
    func transcribeWithTimestamps(fileAt: URL, options: TranscriptionOptions) async throws -> [TranscriptionSegment]

    var onLiveAudioSamples: (@MainActor ([Float]) -> Void)? { get set }
    func resetStreamingSession()
    func startStreaming(options: TranscriptionOptions) async throws
    func switchStreamingDevice() async
    func stopStreaming()
}
```

Protocol-extension defaults throw `TranscriptionEngineError.unsupported(engine:capability:)`,
so a conformer writes only what it does and an unsupported request fails loudly
rather than silently degrading (WHI-42's rule).

`TranscriptionOptions` is deliberately narrow — `mode` (`.transcribe`/`.translate`)
and `language`. WhisperKit's sample length, prefill caches and temperature
fallbacks stay inside the conformer that understands them, so a second engine
never has to widen the type. `TranscriptionModelInfo` and
`TranscriptionEngineState` are the other two neutral types.

**Three conformers.**

| Engine | Conformer | Capabilities |
|---|---|---|
| `.whisperKit` | `WhisperKitTranscriber` (`Client/WhisperKitTranscriber+Engine.swift`) | file, buffer, timestamps, streaming, managed models, translation |
| `.whisperViaBYOK` | `RemoteBatchTranscriber` (new) | file, buffer |
| `.whisperaStreaming` | `StreamingTranscriber` (new) | streaming, file, buffer |

The WhisperKit conformance is a pure adapter — every member forwards to a method
that already existed. `RemoteBatchTranscriber` wraps the untouched
`RemoteTranscriber` (its tests still pass unmodified) and adds a WAV encoder for
the raw-buffer path. `StreamingTranscriber` uses `WhisperaDictation` for the
socket, the resampling and the credentials; it only resolves which server to
talk to and turns that package's events into shared UI state.

**The router** — `Client/TranscriptionRouter.swift`, a `@MainActor struct` with
an injectable `engineProvider`, directly mirroring `RecipeRouter`. Conformers are
shared instances, because a streaming engine holds a socket and a local one holds
a loaded model.

**The live UI is reused, not duplicated** — `Client/LiveTranscriptionState.swift`.
`confirmedText`, `pendingText`, `stableDisplayText`,
`shouldShowLiveTranscriptionWindow`, `isTranscribing`, `isWaitingForModel`,
`waitingForModelStatusText`, `currentText` and `onConfirmedTextChange` moved out
of `WhisperKitTranscriber` into one `@Observable` object, along with the
two-segment confirmation buffer and the flicker filter, moved verbatim.
`WhisperKitTranscriber` exposes all of them as forwarding computed properties, so
its callers and tests are unchanged. `DictationView`, `LiveTranscriptionView` and
`LiveTranscriptionWindow` now bind to the shared state. There is no second view,
and `DictationWordTracker` keeps typing remote text into the focused app through
the same `onConfirmedTextChange` hook.

`AudioManager` talks only to `SpeechTranscribing`. It pins the engine for the
duration of a dictation (`sessionTranscriber`) so a Settings change mid-recording
cannot route stop, or a device switch, at an engine that never started.

## Selecting a remote engine at runtime

**UserDefaults, `UserDefaults.standard`, no env vars.**

| Key | Values | Default |
|---|---|---|
| `whisperaTranscriptionEngine` | `whisperKit` · `whisperViaBYOK` · `whisperaStreaming` | `whisperKit` (also the fallback for any unrecognised value) |
| `whisperaTranscriptionServerURL` | base URL of the transcription backend, e.g. `http://192.168.50.184:3000` | empty → falls back to `whisperaServerURL` |
| `whisperaTranscriptionServerId` | server id from `GET /transcription/servers`, e.g. `speaches-lan` | empty → the backend's own default realtime server |
| `whisperaByokTranscriptionModel` | model name for the BYOK upload endpoint | `whisper-1` |

In the UI: **Settings → General → Transcription → Engine**. Picking
"Whispera server (streaming)" reveals the URL and server-id fields.

Auth is a bearer token from the Keychain via `AuthTokenStore` (service
`com.whispera.clerk`, account `session`) — the same store the account path uses.
Against the test backend (`NODE_ENV=test`) the token *is* the user id, so saving
`demo-user` there is enough. The credential is minted per connect attempt and
once more on the single unauthorized retry, so a short-lived token survives a
reconnect.

Capabilities, the realtime path and the audio format are read from
`GET /transcription/servers` — nothing about `pcm16`/24000 Hz is hardcoded in the
app; the package owns the conversion.

## Engine picker: un-pinned, deliberately

I restored the stored lookup and shipped the picker. The old getter ignored the
stored value while the setter still wrote it, so the ticket's warning was real —
but nothing in production ever called that setter, so no shipped install can hold
a non-default value, and every engine now has a conformer behind it rather than a
dead enum case. **Confirm you want this**: the moment this build ships, a
`whisperaTranscriptionEngine` key holding `whisperViaBYOK` (only reachable by
hand-editing defaults today) would route dictation off-device on first launch.

## What I ran, and what came back

- `GET http://192.168.50.184:3000/transcription/servers` with `Authorization: Bearer demo-user`
  → 200, one server: `speaches-lan`, model `Systran/faster-distil-whisper-large-v3`,
  capabilities `["batch","realtime"]`, realtime path `/transcription/stream?server=speaches-lan`,
  audio `pcm16` / 24000 Hz / mono / `base64-json`.
- Full build on the build Mac (`192.168.50.89`, Xcode 26.2), after rsyncing both
  the worktree and the package:
  `xcodebuild -scheme Whispera -destination "platform=macOS,arch=arm64" -derivedDataPath build/test-derived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build`
  → **BUILD SUCCEEDED**. `WhisperaDictation.swiftmodule` and `.o` are in the
  products directory, so the package really did resolve, compile and link. The
  repo's `swift-format lint` build phase passed over the new files.
- `xcodebuild test -only-testing:WhisperaUnitTests` on this branch: one complete
  pass. Every suite passed except six tests, listed below.
- `Package.resolved` is byte-identical before and after — a local package adds no pin.

## The package dependency is NOT what the brief specified

The brief said to pin `whispera-components` to branch `feat/swift-dictation-component`.
That is not possible today, for two independent reasons I verified:

1. **The branch has never been pushed.** `git ls-remote --heads origin` on the
   checkout returns only `refs/heads/main` (`a0b114e`). The local tip `fb22655`
   exists nowhere but that worktree.
2. **The manifest is not at the repo root.** It lives at `apple/Package.swift`,
   and SwiftPM cannot point a URL dependency at a subdirectory. So even `main`
   could not be consumed by URL.

What I did instead: an `XCLocalSwiftPackageReference` with
`relativePath = ../../whispera-components-worktrees/dictation/apple`, plus an
`XCSwiftPackageProductDependency` on `WhisperaDictation` linked into the app
target. It builds, but it depends on that sibling checkout existing next to the
worktree — I rsynced it to the build Mac at the mirrored path.

**Decision for the owner:** push the branch and move the manifest to the repo
root (or split the Apple package into its own repo), then swap this one pbxproj
node for an `XCRemoteSwiftPackageReference`. Nothing else in the app changes.

## Unfinished

- **Six tests failed on this branch and I did not get them baselined.** All in
  `WhisperaUnitTests`:
  `FileTranscriptionTimestampE2ETests/{timestampedTranscriptionCarriesTimestampsInEveryLine, plainTranscriptionCarriesNoTimestamps, queuePathProducesTimestampsWithFreshDefaults}`
  and `YouTubeDownloadTranscriptionTests/{queueManagerProcessesYouTubeWithTitle, downloadAndTranscribeWithPrefetchedInfo, downloadAndTranscribeYouTubeVideo}`.
  They all need a downloaded WhisperKit model and/or network, and none of them
  touch the code this change moved — but I am *not* claiming they were already
  red, because I never got a clean baseline. Every attempt to run the base tree
  hit the known "Early unexpected exit, never finished bootstrapping" flake, and
  the build Mac ran out of disk mid-way. Treat these six as **unverified**.
- **No live dictation through the backend.** I never drove the real app, so the
  remote path is proven to compile and to resolve a server, not to put words on
  screen. That is the verification that matters and it is outstanding.
- **`switchStreamingDevice()` on the remote engine** activates the selection but
  does not move an established stream; `AVAudioEngine` pins its input at start
  and the package's `MicrophoneSource` takes no device argument. The change
  applies to the next dictation, and it logs that.

## Known issues in what I wrote

Found by an adversarial review pass after the code was written; left unfixed
because you asked me to stop:

- **Two `DictationWordTracker` instances, one callback slot.** `LiveTranscriptionState`
  has a single `onConfirmedTextChange`. `WhisperKitTranscriber`'s tracker
  registers on it, and `StreamingTranscriber.startStreaming` builds its own
  tracker whose `init` overwrites the same slot. Last writer wins. Inert while
  `.whisperKit` is selected; it needs fixing before the streaming engine is used
  in anger. Small fix — hand the tracker to the state instead of letting each
  engine own one.
- **Two debug log lines were dropped** in the segment-confirmation move
  ("New segments to confirm: …" and "No new segments to confirm …"). No UI
  effect, but the exported log is thinner than before.
- **`onConfirmedTextChange` is now `@ObservationIgnored`** where it used to be an
  observed `var`. Nothing reads it from a view body, so this is currently inert.

Everything else in the move was checked line by line against `098bf9b` and found
faithful: the index arithmetic, the `!newConfirmedText.isEmpty` guard, when
`lastConfirmedSegmentCount` advances, the `suffix(2)` pending slice, the ordering
of assignments around `confirmedText`'s `didSet`, and both of the places that
reset the segment counter.

## New tests

`WhisperaUnitTests/LiveTranscriptionStateTests.swift` (19 tests) pins the segment
buffer, the flicker filter and the remote ingest path.
`WhisperaUnitTests/TranscriptionRouterTests.swift` pins that every engine
resolves to a conformer, that conformers are reused, the capability matrix, and
the WAV encoder. **These have not been run** — they were written after the last
successful test pass.
