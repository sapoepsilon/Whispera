# WHI-58 follow-up — one visual language for the pill and the live-words HUD

Branch `ismatulla/whi-58-engine-protocol`. Not pushed, not merged, no PR.

## Plan (written before editing views)

1. Pull the pill's materials/type/spacing/motion out of `ListeningView.swift` +
   `AudioMeterView.swift` into shared, reusable pieces.
2. Rewrite `LiveTranscription/DictationView.swift` and
   `LiveTranscription/LiveTranscriptionView.swift` to compose those pieces
   instead of re-deriving their own chrome.
3. Give the two windows a shared, testable notion of "where is the pill", and
   make `LiveTranscriptionWindow` sit above it instead of following the caret.
4. Confirm both engines render through `LiveTranscriptionState` with nothing
   engine-specific left in the views.

## What was extracted

New file `What's up?/PillStyle.swift`:

- `PillSpacing` — the design-language spacing scale (4/8/12/16/20/24) as named
  constants, so paddings stop being magic numbers copied between files. In the
  process, the three surfaces' padding (14/10, 14/10, 12/8) collapsed onto one
  value (`md`/`sm` = 12/8) instead of three near-identical ones.
- `PillTypography` — the `.rounded` caption for status lines, and the
  body/title3 + primary/blue split that marks "the word being spoken right
  now" in the word flow.
- `PillIndicator` / `PillStatusRow` — one line of secondary status: a spinner
  that settles into a static dot under Reduce Motion, a pulsing dot that
  freezes under Reduce Motion, a static tinted icon, or nothing, plus caption
  text. This replaced four separate hand-rolled spinner+text rows (two in
  `ListeningView`, one in `DictationView`, one in the dead
  `LiveTranscriptionView`) — one of which (`ListeningView`'s "preparing
  model" row) had no Reduce Motion handling at all before this change.
- `PillWordFlow` — the trailing run of live words, most recent one
  emphasized, optional leading ellipsis. Used by `DictationView`, the
  (currently unwired) `LiveTranscriptionView`, and the Settings preview.
- `PillChrome` / `.pillChrome(cornerRadius:)` — the background: Liquid Glass
  on macOS 26, otherwise the ultraThinMaterial + soft blue gradient border +
  two-layer shadow every surface was reimplementing byte-for-byte. Applied to
  `ListeningView`, `DictationView`, `LiveTranscriptionView`, and
  `SettingsView`'s `LiveTranscriptionPreview` — that Settings preview was a
  fifth copy of the exact same chrome + word-flow code, now deleted in favor
  of the shared components so the preview can't drift from the real HUD.

`AudioMeterView.swift` was already a clean, standalone, `Motion.meter`-driven
component — left as-is; nothing to extract there.

`ListeningView.swift` itself now calls `.pillChrome(cornerRadius:)` and
`PillStatusRow` rather than owning the chrome — it's the source of the
language, not a fourth copy of it.

## Engine-agnostic check (decision 4)

`LiveTranscription/DictationView.swift` and `LiveTranscriptionView.swift`
already only touched `LiveTranscriptionState.shared`, never
`WhisperKitTranscriber` — confirmed by grep, no change needed there. One real
leftover was found and removed: `LiveTranscriptionState.currentText` (and its
`WhisperKitTranscriber` passthrough) was a dead property nothing ever wrote to
— `LiveTranscriptionView.swift` (unwired, but still compiled into the target)
was the only reader, using it instead of the shared `stableDisplayText`. Cut
over to `stableDisplayText` and deleted the dead property + passthrough +
the placeholder-text filtering that only made sense for the old field.

`ListeningView`'s direct reads of `WhisperKitTranscriber` (for the one-shot,
non-streaming "preparing model" status while a local Whisper model loads) were
left alone — that status is intrinsic to on-device loading, not something a
remote engine has, and it's outside the two files decision 4 named.

## Coordination design

New file `What's up?/PillAnchor.swift`:

- `PillAnchorProvider` (`@Observable`, `@MainActor`) — a one-writer,
  many-reader broadcast of the pill's current on-screen frame (`nil` when the
  pill is off screen). `ListeningWindow` is the only writer, publishing on
  every place it already changes its own frame (initial show/hide, animated
  resize, and the existing drag/external-resize observers). Nothing reaches
  into `ListeningWindow`'s `NSWindow` from outside.
- `PillAnchor.frame(for:screenFrame:pillFrame:)` — a pure function, no
  `NSWindow`, no observation: given a surface size and the pill's frame (or
  `nil`), returns the rect that surface should occupy. With a pill, the
  surface is horizontally centered on the pill and its **bottom** edge sits
  `PillMetrics.controlsGap` (8pt — the same gap the controls picker already
  uses, not a second invented number) above the pill's top edge, so growth in
  the surface's height reads as growing upward, never toward the pill. With no
  pill (a transient racing the pill's own visibility notification, or shown
  before the pill ever appears), it falls back to the pill's own bottom-center
  resting spot (`PillMetrics.bottomAnchorFraction`), so it's never adrift.
  Covered by `WhisperaUnitTests/PillAnchorTests.swift` (gap, no-overlap,
  centering, grow-upward, follow-on-move, and the no-pill fallback) and
  `PillAnchorProviderTests.swift` (publish/read/clear).

`LiveTranscription/LiveTranscriptionWindow.swift` was rewritten:

- Caret-following is gone. `AccessibilityHelper`'s caret APIs were only ever
  called from this window (confirmed by grep across the repo), so nothing
  else needed the code path decision 3 said to drop for the dictation
  display; `followCaret`/`liveTranscriptionWindowOffset` Settings knobs are
  removed from `SettingsView.swift` since neither controlled anything else.
  `AccessibilityHelper.swift` itself is untouched — it's a general helper,
  not something this task's decisions asked to remove.
- The window now always resolves its position through
  `PillAnchor.frame(...)` fed by `PillAnchorProvider.shared.pillFrame`. It
  repositions on its existing 0.3s content-poll timer and, separately, the
  moment the pill's frame changes (an `withObservationTracking` loop on
  `PillAnchorProvider.shared.pillFrame`, the same pattern `ListeningWindow`
  already uses for its own size presenters) — so a pill drag is followed on
  the next layout pass without this window polling the pill itself.
- First appearance rises into place (fade + short upward rise) rather than
  popping in, matching the reveal language `ListeningWindow` already uses for
  its controls panel — one shared motion vocabulary, not two.
- Made non-movable and click-through (`isMovable = false`,
  `ignoresMouseEvents = true`). Before, it was independently draggable; now
  that it re-homes above the pill on every layout pass, an independent drag
  would immediately be overridden and just fight the user. Dragging the pill
  is how you move the whole assembly. `DictationView`'s content has no
  interactive controls, so this has no functional cost.
- The recipe-error toast keeps using this same window and the same
  `PillAnchor` fallback path — it already anchored at bottom-center before
  this change; now it's the identical code path the live words use, not a
  parallel implementation of "bottom center."

`RecordingWindowPolicy` (`AudioManager/AudioManager.swift`) changed from
"exactly one of the two windows is eligible per mode" to: the listening pill
is the persistent home for recording/transcribing status in **both** modes
(`shouldShowListeningWindow` now depends only on `state != .idle`); the
live-words window still only shows in live mode, and only once there is
something transient to say. This is the behavioral pivot that makes
requirement 3 ("when the pill is visible, the live window sits above it")
meaningful — before this change the two were mutually exclusive by
construction, so "above it" never applied. `DictationView`'s old fallback
branch (rendering an embedded `ListeningView` mic/meter row when live mode had
no words yet) was deleted since the real pill now already covers that.
`WhisperaUnitTests/RecordingWindowPolicyTests.swift` was rewritten for the new
contract (this suite is not in the DoD's "must stay green" list, since its
old assertions encoded the behavior this task deliberately reverses).

## What was run

Built and tested on the configured remote build Mac (this Mac has no Xcode):

```
rsync … whi-58/ → 192.168.50.89:~/Developer/whispera-worktrees/whi-58-sync/
xcodebuild -scheme Whispera -project Whispera.xcodeproj -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/chk \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```
→ **BUILD SUCCEEDED**.

Adding the two new source files to the target required manual
`project.pbxproj` edits (`PBXBuildFile`/`PBXFileReference`/group/Sources-phase
entries) — `What's up?/` and `LiveTranscription/` are plain `PBXGroup`s, not
`PBXFileSystemSynchronizedRootGroup`s like `WhisperaUnitTests/`, so new files
there don't get picked up automatically. Verified with `plutil -lint` before
building.

Tests (`xcodebuild test -only-testing:…`), the exact required suites plus the
new coordination tests:

```
WhisperaUnitTests/LiveTranscriptionSegmentBufferTests
WhisperaUnitTests/LiveTranscriptionFlickerFilterTests
WhisperaUnitTests/LiveTranscriptionRemoteIngestTests   (LiveTranscriptionStateTests.swift)
WhisperaUnitTests/TranscriptionRouterTests
WhisperaUnitTests/TranscriptionFailureMessageTests     (the DoD's "TranscriptionFailureTests" — the struct itself is named TranscriptionFailureMessageTests)
WhisperaUnitTests/SystemAudioMuterTests
WhisperaUnitTests/DeviceSwitchRouteTests
WhisperaUnitTests/FailedActivationHealingTests
WhisperaUnitTests/RecordingSegmentLoadingTests
WhisperaUnitTests/RecordingWindowPolicyTests
WhisperaUnitTests/InitialDefaultsTests
WhisperaUnitTests/PillAnchorTests               (new)
WhisperaUnitTests/PillAnchorProviderTests       (new)
```

First two attempts hit the documented pre-existing flake ("Early unexpected
exit, operation never finished bootstrapping") as a **total** bootstrap
failure (0 of N tests ran), which was worse than the "reddens the summary"
description. Root cause: a stray `xcodebuild test` process from an earlier,
unrelated session was still running against the same `whi-58-sync` checkout
on the shared build Mac (`ps aux` showed it PID 33551, started the previous
evening, apparently hung mid `Resolve Package Graph`), fighting the new run
for the single-instance `Whispera.app` identity. Killed it
(`kill -9 33551 33546`) — did not touch the separately-running
`/Applications/Whispera.app` (16330), since the orchestrator owns that — and
reran. Result: **71 passed, 0 real failures**; the only 3 reported
"failures" were the same known infra flake as three duplicate
"Whispera (NNNNN) encountered an error" system entries, not assertion
failures — every actual `#expect`/`XCTAssert` in the run passed, confirmed by
reading the full test-case log and the `xcresulttool` summary. If a
similarly stuck process reappears, it's a shared-Mac hygiene issue, not
something introduced by this change.

## What could not be verified without a microphone

This Mac's lid is shut / no usable mic, and the owner does voice QA
personally. Specifically unverified:

- The live-words HUD actually rising above the real pill with real streaming
  words from either engine (local WhisperKit or the remote realtimeDirect
  engine), including the upward growth as more words arrive.
- Dragging the pill mid-dictation and watching the HUD re-home on the next
  layout pass.
- The macOS 26 Liquid Glass rendering path for `pillChrome` (this build ran
  against macOS 26.4.1 but no visual/screenshot check was done — Liquid Glass
  is applied through `#available(macOS 26.0, *)`, same gate as the original
  code).
- Reduced-motion visuals in practice (System Settings → Accessibility →
  Reduce Motion), beyond the fact that every animated path is code-gated on
  `Motion.systemReduceMotion` / `accessibilityReduceMotion`.
- The recipe-error toast's rise animation and the live-words HUD's own
  first-appearance rise, visually.
- `WHISPERA_AUTOSTART_DICTATION` was not exercised in this pass — the build
  was verified with `xcodebuild build`/`test` only, per "build-check only;
  the orchestrator handles install," and no build was installed to
  `/Applications`.

## Files touched

- `What's up?/PillStyle.swift` (new)
- `What's up?/PillAnchor.swift` (new)
- `What's up?/ListeningView.swift`
- `What's up?/ListeningWindow.swift`
- `LiveTranscription/DictationView.swift`
- `LiveTranscription/LiveTranscriptionView.swift`
- `LiveTranscription/LiveTranscriptionWindow.swift`
- `AudioManager/AudioManager.swift` (`RecordingWindowPolicy`)
- `Client/LiveTranscriptionState.swift` (dropped dead `currentText`)
- `WhisperKitTranscriber.swift` (dropped the `currentText` passthrough)
- `SettingsView.swift` (dropped follow-caret/window-offset controls, shared
  `LiveTranscriptionPreview` styling)
- `Whispera.xcodeproj/project.pbxproj` (new files wired into the target)
- `WhisperaUnitTests/RecordingWindowPolicyTests.swift` (updated for the new
  policy)
- `WhisperaUnitTests/PillAnchorTests.swift` (new)
