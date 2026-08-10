# WHI-58 polish — reliability, usability, house style

Branch `ismatulla/whi-58-engine-protocol` (app) and `feat/swift-dictation-component`
(package). Not pushed, not merged, no PR.

The earlier WHI-58 build record — the protocol, the three conformers, the shared
live state — is the version of this file at commit `563c913`. This one records
the polish pass on top of it.

## Plan (written before any behaviour changed)

### 1. Reliability

**Root cause first, workaround second.** The `InternalServerError` that kills a
speaches session ~1.5 s after the first transcript is not a transcription fault.
Its traceback ends in `speaches/routers/chat.py` → `openai.APIConnectionError`:
the OpenAI Realtime API is conversational, so after server-side VAD closes an
utterance speaches auto-generates an assistant *response* and routes it at a
chat-completions backend that is not configured on that host. The socket dies
with it. speaches ignores `intent=transcription` but does accept
`turn_detection: {type: "server_vad", create_response: false}` in
`session.update`.

So:

1. `RealtimeProtocol.sessionUpdate` sends `turn_detection` with
   `create_response: false`. That removes the cause. Because sending
   `turn_detection` at all replaces the engine's VAD block, the learned
   `silence_duration_ms` from `session.created` is echoed back, or the trailing
   silence budget the session computes from it goes stale.
2. A **bounded reconnect** stays, for closes that are genuinely unexpected.
   `DictationError` grows an `isRecoverable` classification — server error,
   unexpected close, dropped connection are recoverable; a rejected credential
   after the permitted retry, an unavailable credential, a protocol violation,
   unavailable audio and a cancelled session are terminal. `DictationSession`
   reconnects once, with backoff, and only while the audio source can be
   resubscribed (the microphone can; a file or a drained push source cannot, and
   retrying those would send silence and call it success).
3. A first-connect transport failure goes through the same budget, so the
   intermittent `connectionFailed("The Internet connection appears to be
   offline.")` retries before it is surfaced.
4. `DictationConnectionState` grows `.reconnecting(attempt:)` so the gap is
   visible in the UI rather than hidden. Audio spoken during the gap is lost;
   that is stated on screen.

All of it is pinned by checks that never touch the network, in
`Sources/DictationChecks`.

### 2. Usability

1. Direct mode gets the engine-URL and model fields in Settings, composed from
   the existing `SettingsSection`/`SettingRow`, so `defaults write` is no longer
   required.
2. Choosing a server engine turns live transcription on, and says so, rather than
   silently leaving the user on the record-then-transcribe path that looks broken.
3. `LiveTranscriptionState.waitingForModelStatusText` carries connecting,
   listening, reconnecting and failure, each in plain language.
4. Failures raise a `.alert()` with the `presenting:` data pattern, carrying a
   message that says what to do. The HUD keeps only the short status line.

### 3. Style

`design-language.md` spacing (4/8/12/16/20/24), `.easeInOut(duration: 0.2)` on
state, `.easeOut(duration: 0.1)` on presses, no new section style, no emoji, no
`print`, reduced-motion respected.

## Outcome

_Filled in below once the work was done and driven._
