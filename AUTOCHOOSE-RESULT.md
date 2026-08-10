# WHI-58 follow-up: automatic engine/tier selection

An `auto` `TranscriptionEngine` that picks the best available transcription path —
native-delta server, synthesized-delta server, utterance-only server, or on-device
WhisperKit — without the user configuring anything. Branch
`ismatulla/whi-58-engine-protocol`. Neither this change nor its tests touch the
sibling `WhisperaDictation` package (`../../whispera-components-worktrees/dictation/apple`).

## The one thing the package can't give us yet

`WhisperaDictation.DictationServer` (`ServerDiscovery.swift`) does not decode
`realtime.granularity` — the field this whole feature ranks servers on. The package's
own `GET /transcription/servers` request (`DictationServerDirectory.servers()`) drops
it silently because its `Realtime` struct doesn't declare the property.

Rather than edit the package, `Client/AutoTranscriber.swift` adds `ServerDiscoveryProbe`:
an app-side `Decodable` mirror of the same response (`id`, `label`, `capabilities`,
`status`, `default`, and `realtime.granularity`), built with the exact same request shape
the package uses (same path, same credential-in-header/query-item placement) so the two
can't quietly drift apart. It talks to the credential protocol
(`DictationCredentialProvider`, public) directly — no package-internal API needed.

**The one-line package change that would let this go away:** add `public let
granularity: String?` to `DictationServer.Realtime` in `ServerDiscovery.swift`, and drop
`ServerDiscoveryProbe` in favor of `DictationServerDirectory.servers()`. Everything else
here — the ranking, the caching, the conformer — is unaffected either way.

This was checked against the real thing, not just imagined: hit the live dev backend at
`http://127.0.0.1:3000/transcription/servers` (bearer `demo-user`) directly, and its
sibling's delta-synthesis work has already landed *and* a native NeMo engine is already
registered:

```json
speaches-lan   default:true   capabilities:[batch,realtime]  granularity: synthesized-delta
speaches-plain default:false  capabilities:[batch,realtime]  granularity: utterance
nemo-stream    default:false  capabilities:[realtime]        granularity: native-delta
```

Running the probe's exact decode + ranking logic against that live payload (via a
throwaway `swift` script, not committed) picks `nemo-stream` — the non-default,
native-delta server — over the backend's own flagged default. That is the feature
working as specified: rank beats "default" when nothing is pinned.

## Resolution policy (`AutoEnginePolicy.resolve`, pure, in `Client/AutoTranscriber.swift`)

| serverURLConfigured | discovery | pinnedServerId | usable servers | → |
|---|---|---|---|---|
| false | — | — | — | local — "no transcription server configured" |
| true | unavailable (timeout/error) | — | — | local — "backend unreachable" |
| true | servers([]) or none online+realtime | — | — | local — "no realtime server available" |
| true | servers | non-empty, found among usable | — | that pinned server, its own granularity |
| true | servers | non-empty, **not** found/usable | — | falls through to ranking below (pin isn't a dead end) |
| true | servers | empty | ≥1 usable | best by granularity rank (native-delta > synthesized-delta > utterance), ties broken by the backend's own `default` flag, then id |

Absent or unrecognised `granularity` decodes to `.utterance` — the worst rank, not the
best — so an older backend, or one whose delta-synthesis hasn't landed, degrades to
"looks like it has no live words" rather than being assumed to have the best kind.

Discovery runs with a 3s request timeout (`ServerDiscoveryProbe`'s
`URLRequest.timeoutInterval`) and the resolved answer is cached for 20s
(`AutoTranscriber.cacheTTL`) — resolved fresh at the top of every `prepare()`,
`startStreaming()`, and one-shot `transcribe()` call, not on every audio frame, and not
re-fetched on a rapid stop/start inside that window.

## Default for fresh installs: `auto`

`WhisperaSettings.transcriptionEngine`'s fallback (`Client/TranscriptionRouter.swift`)
changed from `.whisperKit` to `.auto` for absent/unrecognised stored values, and
`SettingsView`'s `@AppStorage` default followed it, so the picker and the runtime default
never disagree.

This was verified safe rather than assumed: nothing in `WhisperaUnitTests` constructs an
`AudioManager` or otherwise exercises `TranscriptionRouter`'s default-resolution path —
every existing test that touches the router passes an explicit engine or an explicit
`engineProvider`. Ran the full `WhisperaUnitTests` target after the change; everything
that could plausibly be sensitive to the default (`TranscriptionRouterTests`,
`ServerEngineTests`, `TranscriptionFailureTests`, streaming/live-transcription suites)
stayed green. This is honest, not just convenient: `auto` with no server configured
resolves to exactly what `.whisperKit` used to mean, so a fresh install behaves
identically to before until the user points it at a server.

## `auto` as a conformer, not a `switch` case

`AutoTranscriber` (`Client/AutoTranscriber.swift`) is a `SpeechTranscribing` conformer in
its own right — `engine == .auto` — that resolves at the top of every call and delegates
to whichever of `WhisperKitTranscriber.shared` or an internally-held `StreamingTranscriber`
it picked. This, not a `switch` on `.auto` somewhere in `AudioManager` or
`TranscriptionRouter`, is why `TranscriptionRouter.transcriber(for:)` stays exhaustive
without reopening — `TranscriptionRouterTests.everyEngineResolvesToAConformer` already
enforced that shape, and it still does with `.auto` in the loop.

Two consequences worth stating plainly:

- `TranscriptionEngine.auto.streamsFromAServer` is `false` even though `auto` may end up
  streaming, because `ServerEngineTests.everyServerEngineResolvesToTheStreamingConformer`
  asserts every engine that answers `true` there resolves to a `StreamingTranscriber`
  instance specifically — `AutoTranscriber` isn't one. Because of that, the existing
  "turn on Live Transcription Mode to see live words" `InfoBox` in `SettingsView` — gated
  on `streamsFromAServer` — would have silently stopped applying to `auto`, even though
  its wording is engine-agnostic and the caveat is exactly as true whether `auto` lands on
  a server or on WhisperKit. Its visibility condition now also checks `== .auto` directly
  rather than folding that into `streamsFromAServer`'s meaning.
- Model management (`models()`, `selectModel`, `downloadModel`) always addresses the
  on-device model bank, unconditionally on the currently-resolved delegate — mirroring
  the existing "Whisper Model" Settings section, which is already unconditional on the
  engine picker. There is no server for a user to manage models against under `auto`
  even on a run that happens to stream.
- A remote pick is not `StreamingTranscriber.shared` (which would resolve through the
  package's own default-first logic, ignoring granularity) but a second, dedicated
  `StreamingTranscriber` instance inside `AutoTranscriber`, pointed at the specific server
  id the policy chose via an injected `serverIdProvider`. This costs one extra discovery
  round trip per resolution (the probe, then that instance's own `resolveServer()` when it
  actually connects) — accepted rather than engineered away, since avoiding it would mean
  either mutating the user's pinned-server setting to reflect an auto pick (dishonest: it
  would look like the user chose it) or touching the package to expose granularity through
  the existing directory (out of scope here).

## Settings

The picker gains `.auto` as `"Automatic (recommended)"`, first in `TranscriptionEngine`'s
case order so it's also first in the picker. Selecting it shows a caption block (same
pattern as the existing streaming/direct-mode blocks) with a static explanation plus a
live one-liner — `AutoTranscriber.resolutionCaption()` — fetched via `.task(id:)` the same
way the direct-mode model list already refreshes itself, sharing the same 20s cache a
dictation would use rather than triggering its own round trip.

## Status legibility

`AutoTranscriber.apply(_:)` sets `LiveTranscriptionState.shared.waitingForModelStatusText`
to `resolution.summary` (e.g. `"auto: server nemo-stream (native-delta)"` or `"auto: local
WhisperKit (backend unreachable)"`) once, at the top of resolution, before delegating.
The delegate's own `startStreaming` immediately refines that with its usual
connecting/loading text — expected, since this is only the first word on what `auto`
picked and why. The same line goes to `AppLogger.shared.transcriber.info`.

## Tests

`WhisperaUnitTests/AutoEnginePolicyTests.swift` — ten pure `AutoEnginePolicy.resolve`
cases: no URL, discovery failure, no usable server, native > synthesized > utterance
ranking, absent-granularity-degrades-not-wins, default-flag tie-break, a pin winning over
better-ranked alternatives, a stale/unusable pin falling through to ranking rather than
dead-ending, and the summary string's exact wording. No network, no `MainActor`, no
backend.

Small additions to existing suites rather than new ones: `TranscriptionRouterTests` gained
`autoResolvesToTheAutoTranscriber`, `anAbsentOrUnknownStoredEngineFallsBackToAuto`, and an
`.auto` case in `resolvingTwiceReturnsTheSameInstance`; `ServerEngineTests` gained one
assertion that `.auto.streamsFromAServer` is `false`.

## What was run

- `xcodebuild … -scheme Whispera build` — succeeded, on the remote build Mac (this Mac
  has no full Xcode), synced via `rsync` per the environment recipe, both the app worktree
  and the `whispera-components-worktrees/dictation/apple` package copy.
- `xcodebuild … -only-testing:WhisperaUnitTests test` — full target run, exit 0. Read
  individual test-case lines rather than trusting the summary line (known bootstrap
  flake). Every `TranscriptionRouterTests`, `ServerEngineTests`,
  `TranscriptionFailureMessageTests`, `AutoEnginePolicyTests`, `StreamingTranscriberDirectModelsTests`,
  `LiveTranscriptionSegmentBufferTests`/`LiveTranscriptionRemoteIngestTests`/`LiveTranscriptionFlickerFilterTests`,
  `PillAnchorTests`/`PillAnchorProviderTests`, `RecordingWindowPolicyTests`,
  `DeviceSwitchRouteTests`, `FailedActivationHealingTests`, `RecordingSegmentLoadingTests`,
  `LiveDictationPasteTests`, and `SystemAudioMuterTests` case passed. The one failure in
  the run, `YouTubeDownloadTranscriptionTests.queueManagerProcessesYouTubeWithTitle`
  (180s timeout), is a pre-existing real-network YouTube integration test unrelated to
  transcription engine routing — untouched by this change.
- A throwaway `swift` script (not committed) decoding the live backend's real
  `/transcription/servers` response with `ServerDiscoveryProbe`'s exact shape and running
  `AutoEnginePolicy`'s ranking against it — confirmed above.
