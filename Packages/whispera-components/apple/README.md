# WhisperaComponents

Visual components, a streaming dictation component, and the client layer beneath both, covering
iOS 17 and macOS 14.

| Product | What it is | Depends on |
| --- | --- | --- |
| `WhisperaComponents` | RecordingGlow, AudioMeter, EdgeMagnet — SwiftUI + Metal | Metal |
| `WhisperaDictation` | Streaming speech-to-text transport. No UI. | Foundation, AVFoundation |
| `WhisperaDictationUI` | A drop-in dictation view and its primitives | `WhisperaDictation` |
| `WhisperaOpenAI` | One client for any OpenAI-compatible server | Foundation, Security |
| `WhisperaRecipes` | Prompt templates with a trigger phrase, and the runner | `WhisperaOpenAI` |
| `WhisperaBackend` | The thin layer that talks to the Whispera backend | the three above |
| `WhisperaLink` | The Mac ↔ iPhone link: device keys, WL1 signing, pairing, approvals, the relay's E2E envelope | Foundation, CryptoKit, Security, LocalAuthentication |
| `WhisperaLinkServer` | Verifying incoming signed requests, replay cache — for the Mac helper | `WhisperaLink` |

The dictation targets do **not** depend on `WhisperaComponents`: that one carries Metal shaders,
which `swift build` cannot compile, and dictation has no business requiring a GPU toolchain. They
read the same `tokens.json` instead — see [Where the constants come from](#where-the-constants-come-from).

The three visual components come from **one target** covering iOS 17 and macOS 14.

The originals were AppKit-bound. Making them multiplatform was the point of the port, so the parts
that could not cross are shimmed rather than shipped — see [Porting notes](#porting-notes).

## Adding it to a package

`Package.swift` is at the **repository root**, so the package is consumable by git URL. The Swift
sources still live under `apple/`; every target in that manifest names its path explicitly.

```swift
dependencies: [
    .package(url: "https://github.com/sapoepsilon/whispera-components", exact: "0.1.1")
],
targets: [
    .target(
        name: "YourApp",
        // "whispera-components" — a URL dependency is identified by the last path
        // component of its URL, not by the `name:` in its manifest
        dependencies: [
            .product(name: "WhisperaOpenAI", package: "whispera-components"),
            .product(name: "WhisperaRecipes", package: "whispera-components"),
        ]
    )
]
```

A path dependency still works and now points at the repository root rather than at `apple/`:

```swift
.package(path: "../whispera-components")   // package identifier: "whispera-components"
```

Verified from a clean clone: `swift build` and both self-test executables run at the root, and a
throwaway consumer outside the repo builds against all four library products by URL. The
`DictationDemo` executable carries `.unsafeFlags` to embed its `Info.plist`, which is legal here
because it belongs to no library product — a versioned dependency only rejects unsafe flags on
targets reachable from a product the host actually uses.

## RecordingGlow

```swift
import WhisperaComponents

RecordingGlowView(level: audioLevel)                 // 0…1
RecordingGlowView(level: audioLevel, color: .orange)
```

Takes a plain `Float`, not an audio engine: the package has no business knowing where the number
came from, and a caller on iOS has a different source than one on macOS. Smoothing (fast attack,
slow release) and the idle breathing pulse happen inside, so pass the raw level every frame.

Honours `accessibilityReduceMotion` by holding the rest state — the band still draws, only the
motion stops.

## AudioMeter

```swift
AudioMeterView(levels: levels)                    // [Float], one per bar
AudioMeterView(levels: levels, fixedHeight: 60)   // pin the height
```

Bar width, spacing, height range, capsule radius and the spring all come from tokens rather than
`@AppStorage`, which is what makes it a component rather than a view wired into one app's settings.

## EdgeMagnet

```swift
EdgeMagnetView(
    sourceRect: windowRect,
    route: .surfaceBorder,            // or .rect(caretRect) to gather into a caret
    profile: .onboarding,             // or .dictation
    onSourceShouldVanish: { hideWindow() },
    onCompleted: { teardown() },
    onFailure: { error in log(error) }
)
```

200k particles are affordable because nothing is stored per particle: every attribute is derived in
the shader from the instance id, so any frame can be drawn without the ones before it.

Rendering runs on its own thread and paces itself off `nextDrawable()`, because the animation plays
while the host is often busy on the main actor — that stalled it mid-flight in the shipping app.

`onFailure` exists so a Metal setup problem is reported rather than leaving a caller waiting on a
completion that never arrives.

## Dictation

Streaming speech-to-text: the user speaks, words arrive as they talk. Two layers, separately
importable, because a host that wants text and a host that wants a working screen want different
things.

### Just the text — `WhisperaDictation`

No SwiftUI anywhere in this target's dependency graph. Import it alone and drive your own UI:

```swift
import WhisperaDictation

let session = DictationSession(
    configuration: .backend(
        URL(string: "https://api.whispera.app")!,
        model: "Systran/faster-distil-whisper-large-v3"),
    credentials: .refreshingBearer { try await clerk.session.getToken() },
    audio: MicrophoneSource())

await session.start()
for await event in session.events {
    switch event {
    case .partialTranscript(let text): draft = text        // may still be revised
    case .finalTranscript(let text):   commit(text)
    case .transcript(let text):        textView.string = text   // everything so far
    case .audioLevel(let level):       meter.level = level
    case .connectionState(let state):  status = state
    case .failed(let error):           show(error)
    }
}

// When the user stops: flush, wait for the engine's last words, tear down.
let transcript = await session.finish()
```

The one-line version, when the protocols are not needed:

```swift
let session = await DictationSession.start(
    configuration: .backend(backendURL, model: model),
    credentials: .bearer(token)
) { event in
    if case .transcript(let text) = event { print(text) }
}
```

And for a finite source — a recording already on disk — there is no stream to consume at all:

```swift
let text = try await DictationSession.transcribe(
    configuration: .backend(backendURL, model: model),
    credentials: .bearer(token),
    audio: try AudioFileSource(url: recording))
```

### A working screen — `WhisperaDictationUI`

```swift
import WhisperaDictationUI

struct NotesScreen: View {
    @State private var notes = ""

    var body: some View {
        DictationView(
            text: $notes,
            configuration: .backend(backendURL, model: model),
            credentials: .refreshingBearer { try await clerk.session.getToken() })
    }
}
```

Or compose the primitives, sharing one `DictationController`:

```swift
struct CustomScreen: View {
    @StateObject private var dictation = DictationController(
        configuration: .backend(backendURL, model: model),
        credentials: .bearer(token))

    var body: some View {
        HStack {
            DictationMicButton(isRecording: dictation.isRecording,
                               level: dictation.level,
                               action: dictation.toggle)
            DictationLevelMeter(levels: dictation.levels)
            DictationTranscriptText(transcript: dictation.transcript,
                                    partial: dictation.partialTranscript)
        }
    }
}
```

`DictationView` owns its controller. To share one controller between views, or keep it alive past
this screen, use `DictationSurface(controller:)` — the same surface, observing a controller it does
not own. (They are two types rather than two initialisers because `@StateObject` evaluates its
autoclosure once and then keeps that object forever, so handing it an existing controller silently
pins whichever one arrived first.)

All of these snippets are verified: a throwaway consumer package outside this repo builds against
them.

### The microphone

`MicrophoneSource` installs an `AVAudioEngine` tap in the hardware's own format and lets the package
resample. Two things are worth knowing before shipping it:

- **Ask for permission when it suits your UI**, via `MicrophoneSource.requestPermission()`, not at
  the moment the user first taps record. The call is bounded by a timeout because
  `AVCaptureDevice.requestAccess` never returns for a process that cannot raise a prompt — a
  command-line binary with no bundle, or anything without a GUI session — and an unbounded wait
  there is indistinguishable from a hang.
- **On macOS the grant belongs to the responsible process**, which for a terminal binary is the
  terminal application, not your executable. `DictationDemo` embeds an `Info.plist` with
  `NSMicrophoneUsageDescription` for exactly this reason; an app bundle gets it from its own plist.

### Auth is the host's, always

The package never imports Clerk, or any auth SDK. It asks for a `DictationCredential` — headers and
query items — and does not learn what minted them. Swapping providers is one line:

```swift
credentials: .refreshingBearer { try await clerk.session.getToken() }   // Clerk
credentials: .refreshingBearer { try await supabase.auth.session.accessToken }
credentials: .bearer(apiKey)                                            // a plain key
credentials: .fixed(DictationCredential(queryItems: [.init(name: "api_key", value: k)]))
```

The provider is called on **every** connect, and once more after an unauthorized close — then the
connection is retried exactly once. That is what lets Clerk's 60-second tokens survive a reconnect,
and the "exactly once" is what stops a genuinely bad credential from hammering the auth provider in
a loop. A credential never appears in a log: `DictationCredential`'s `description` redacts its own
values, so even interpolating one cannot leak it.

### Audio is injectable

```swift
audio: MicrophoneSource()                 // AVAudioEngine
audio: try AudioFileSource(url: wav)      // a file, for tests and demos
audio: myPushSource                       // your own capture, via PushAudioSource
```

Resampling happens **inside** the package. A source declares its format and the package converts to
the engine's 24 kHz mono PCM16 — a host handing over 48 kHz stereo float from its own tap does not
have to know any of those numbers. Sending the wrong rate is not an error you would notice by
reading the transcript: this engine accepts 16 kHz audio and silently time-compresses it.

### Keeping the audio for a second pass

Streaming favours latency. A host that wants maximum accuracy can re-transcribe the whole session
with a slower model once the user stops — opt in with `retainAudio` and read the audio back after
`finish()`:

```swift
var configuration = DictationConfiguration.backend(backendURL, model: model)
configuration.retainAudio = true

let session = DictationSession(configuration: configuration,
                               credentials: credentials,
                               audio: MicrophoneSource())
await session.start()
// … live words stream in …
let liveTranscript = await session.finish()

let pcm = await session.capturedAudio()            // 24 kHz mono PCM16
if await session.capturedAudioWasTruncated { /* only the last ten minutes survived */ }
```

The copy is the **normalized** audio — resampled, downmixed, exactly the bytes that went to the
wire — without the synthetic trailing silence the flush appends, so a second pass hears what the
streaming engine heard and nothing else. It survives `finish()` and `cancel()` and lives as long as
the session object does.

Retention is off by default because it costs memory: it is bounded at ten minutes of engine-format
audio (24 kHz × 2 bytes × 600 s ≈ 28.8 MB), and past the cap the oldest audio is dropped, the tail
kept, and `capturedAudioWasTruncated` reports that it happened.

### The demo

```bash
swift run DictationDemo --file path/to/speech.wav --direct
swift run DictationDemo --mic --backend http://localhost:3000 --token <token>
swift run DictationDemo --backend http://localhost:3000 --token <token> --list-servers
```

`--direct` talks to an OpenAI-Realtime engine with no backend in front, which is the fastest loop
while developing. `--backend` goes through the Whispera proxy, which is the shipping path — the
backend holds the engine's address and key, so a client never learns either.

## WhisperaOpenAI

One type, any OpenAI-compatible server. "A local model" and "bring your own key" are not two
things — they are this client with a different base URL and a different bearer, and Anthropic is a
third base URL through its OpenAI-compatible endpoint. There is no provider enum, because a closed
set of providers is exactly what makes the fourth endpoint someone stands up unreachable.

```swift
import WhisperaOpenAI

let client = OpenAICompatibleClient(
    baseURL: URL(string: "http://localhost:11434/v1")!,   // or https://api.openai.com/v1
    apiKey: key,                                          // omit for a server that wants none
    logger: OpenAILogger { level, message in log(level, message) })

let text = try await client.complete(
    system: "Be terse.", prompt: "Summarise this.", model: "qwen3:8b", temperature: 0.2)

for try await delta in client.streamChatText(
    ChatCompletionRequest(model: "qwen3:8b", system: nil, prompt: prompt))
{
    draft += delta
}

let models = try await client.transcriptionModels()          // GET /models, filtered by task
let heard = try await client.transcribe(
    TranscriptionRequest(model: "whisper-1", audio: .wav(samples: pcm), language: "en"))
```

Worth knowing:

- **`temperature` is sent.** The client this was extracted from accepted one on every step and
  dropped it, so every recipe that set a temperature behaved as though it had not.
- **Timeouts and one bounded retry.** 20 s by default, and exactly one retry on the transport
  failures that are actually transient — a timeout, a refused connection, a dropped route. An HTTP
  status is an answer from a reachable server and is never retried. Streaming is never retried
  either: a stream that died after its first token cannot be replayed without showing the user the
  same words twice.
- **Streaming does not read `AsyncBytes.lines`.** That sequence collapses consecutive newlines, so
  the blank line that terminates an SSE event never arrives and the stream looks empty. `SSEParser`
  consumes bytes and is chunk-boundary safe — feeding it one byte at a time and feeding it the whole
  body produce the same events, which is what the checks pin.
- **Nothing is logged by default, and nothing is logged unredacted.** `OpenAILogger` takes both an
  emit closure and a redaction closure; the default rule scrubs provider keys, bearer values and
  credential-bearing query parameters, and a host can be stricter.
- **Keys are keyed by server id, not by provider**, and live in the Keychain as
  device-only items read at request time (`OpenAIKeyStore`).

## WhisperaRecipes

A recipe is a prompt template with a trigger phrase, a step list and a local JSON file. No backend
type appears anywhere in this target — `grep -r "WhisperaBackend\|WhisperaAPIClient" Sources/WhisperaRecipes`
returning nothing is a standing acceptance criterion, not an accident.

```swift
import WhisperaRecipes

let store = RecipeStore()                     // or RecipeStore(fileURL: myURL)
store.loadDefaults()                          // four bundled starters, only when empty

if let match = store.match(transcript) {
    let pipeline = RecipePipeline.openAI(client: client, defaultModel: { settings.model })
    let output = try await pipeline.run(recipe: match.recipe, input: match.remainder)
}
```

Matching is word-by-word, not by string prefix: "summarizes the report" must not fire a
"summarize" command, because a dictation that silently rewrites itself over one shared stem is
worse than one that never fires. The longest matching trigger wins.

Steps run in order and each output feeds the next, with `{{input}}` and `{{steps[i].output}}`
interpolated into both the prompt and the system prompt. A step naming no model falls back to the
host's default, which is what lets one recipe run against a local 3B model on one machine and a
hosted one on another without being edited.

`RecipePipeline` runs against anything conforming to `RecipeStepExecuting`, so a host can point
recipes at an on-device model, or at a stub, without this package growing a second code path.

## WhisperaBackend

The layer that knows the Whispera backend's shape — `WhisperaAPIClient` and its recipes and execute
extensions, `AuthManager`, `AuthTokenStore`, `BackendExecutor`, `POST /transcribe`, and the
`auto` engine's resolution policy.

It is deliberately parked, and deliberately alone: nothing else in this package imports it, it
depends on the other three rather than the other way round, and **a host that removes it entirely
must still build, dictate and run recipes**. That is the seam. Credentials cross it as
`DictationCredentialProvider` — the dictation package's own protocol — rather than as a token store,
which is what used to tie the shipping transcription paths to this layer:

```swift
import WhisperaBackend

let store = AuthTokenStore()
let session = DictationSession(
    configuration: .backend(backendURL, model: model),
    credentials: store.credentialProvider,      // a DictationCredentialProvider, nothing more
    audio: MicrophoneSource())
```

`AutoEnginePolicy` is a pure function of what discovery found, so the whole decision table is
exercisable without a backend:

```swift
let servers = try await DictationServerDirectory(baseURL: backendURL, credentials: creds).servers()
switch AutoEnginePolicy.resolve(
    serverURLConfigured: true, pinnedServerId: settings.pinned, discovery: .servers(servers))
{
case .local(let reason):                       useOnDevice(reason)
case .server(let id, _, let granularity):      connect(to: id, expecting: granularity)
}
```

## WhisperaLink

The Mac ↔ iPhone link protocol (whispera-link v1) as one package both apps link: device keys,
WL1 request signing, pairing, the approval bytes the phone signs, the daemon client and its event
stream, the error envelope, and — new here — the end-to-end envelope relay messages travel in plus
a client for the backend's device registry and relay. Foundation, CryptoKit, Security and
LocalAuthentication only; no UIKit, no AppKit.

`WhisperaLinkServer` is the receiving side — verifying incoming signed requests, the replay cache,
pairing and approval signature checks — for the Mac helper. It is a separate product so a phone
never links server code.

```swift
import WhisperaLink

// Keys: Secure Enclave on a device, software keys in the simulator and in tests.
let keys = DeviceKeys(service: "com.example.whispera.link.keys")
let link = try keys.create(.link)                     // signs every request, no prompt
let kem = try keys.createAgreementKey()               // relay envelopes are sealed to this

// Talk to the Mac's daemon (pairing, agents, approvals, SSE events).
let client = LinkClient(baseURL: mac, deviceID: record.deviceID, linkKey: link, daemonPubkey: record.daemonPubkey)
for try await event in client.events() { … }

// Talk to the backend: register once with the account token, then everything is WL1-signed.
let me = try await RelayClient.register(baseURL: backend, accountToken: token,
    RegisterDeviceRequest(name: "iPhone", platform: .current, link_pubkey: link.publicKey.x963Base64,
                          kem_pubkey: try KEMKeyRecord.sign(kem.publicKey, linkKey: link).base64))
let relay = RelayClient(baseURL: backend, deviceID: me.device_id, linkKey: link)
let peers = try await relay.peers()
try await relay.send(payload, to: theMac)                          // sealed + signed here
for try await message in relay.stream(after: lastSeq) {            // or messages(after:wait:)
    let plaintext = try relay.open(message, peers: peers, agreementKey: kem)
    try await relay.ack(upTo: message.seq)
}
```

```swift
import WhisperaLinkServer

let verifier = RequestVerifier { deviceID in store.lookup(deviceID) }   // .active(key) / .revoked / .unknown
switch verifier.verify(method: "POST", target: rawTarget, headers: headers, body: body, now: now, maxBodyBytes: 65_536) {
case .success(let request): handle(request.deviceID)
case .failure(let refusal): respond(refusal.httpStatus, refusal.envelope.encoded())
}
```

### Wire formats

The normative document is `whispera-link/docs/PROTOCOL.md`; this is what the package implements,
byte for byte.

**Keys (§2.1).** P-256. On the wire a public key is standard base64 of the 65-byte X9.63
uncompressed point (`0x04 ‖ X ‖ Y`). Its SPKI DER is the fixed 26-byte prefix
`3059301306072a8648ce3d020106082a8648ce3d030107034200` followed by those 65 bytes; the
**fingerprint** is lowercase hex SHA-256 of the SPKI DER, displayed as its first 16 hex chars in
groups of four (`087b-057a-3759-19bc`). Signatures are ECDSA P-256 / SHA-256, ASN.1 DER, standard
base64. High-S signatures are accepted on verify (CryptoKit and OpenSSL emit them). Each device has
a **link** key (signs requests), an **approve** key (signs approvals; Face ID / Touch ID /
passcode), and an **agreement** key (receives relay envelopes).

**Ids.** `dev_` + 24 chars of lowercase unpadded base32 of 15 random bytes (`^dev_[a-z2-7]{24}$`);
approvals use `apr_` the same way. A nonce is 16 random bytes as unpadded base64url
(`^[A-Za-z0-9_-]{22}$`).

**WL1 request signing (§4).** Four headers — `X-WL-Device`, `X-WL-Timestamp` (Unix seconds,
decimal), `X-WL-Nonce`, `X-WL-Signature` (link key, DER, base64) — over this UTF-8 string, `\n`
separated, no trailing newline:

```
WL1
<METHOD, ASCII upper-case>
<request target exactly as sent: percent-encoded path + "?" + query>
<lowercase hex SHA-256 of the raw body; e3b0c442…b855 when empty>
<X-WL-Timestamp>
<X-WL-Nonce>
<X-WL-Device>
```

The target is built from the final `URL`, so an agent id `w3:p1` is signed as `w3%3Ap1`. The
receiver checks, in order: headers present (`auth_missing`) → device known (`auth_unknown_device`)
and not revoked (`auth_revoked`) → `|now − ts| ≤ 60 s` (`auth_clock_skew`, with `server_time`) →
body within the route limit (`payload_too_large`) → signature (`auth_bad_signature`) →
`(device, nonce)` unseen for 120 s (`auth_replay`). A nonce is remembered only after its signature
verified. Clients that get `auth_clock_skew` adopt `server_time` as their offset and retry once.

**Other signed messages.**

| Message | Bytes signed | Key |
| --- | --- | --- |
| Pairing proof (§3.3) | `WL1-PAIR-PROOF\n<code>\n<daemon_fp>\n<sha256hex(approve x963)>` | link |
| Pairing approve-proof | `WL1-PAIR-APPROVE\n<code>\n<daemon_fp>` | approve |
| Pairing response (`X-WL-Server-Signature`) | `WL1-PAIR-RESP\n<sha256hex(response body)>` | daemon |
| Approval (§7.2) | `WL1-APPROVE\n` + the broker's canonical bytes, verbatim | approve |

**Canonical approval (§7.1).** The broker's request as compact JSON with sorted keys and
`\uXXXX` escapes for non-ASCII — `v`, `request_id`, `nonce`, `op`, `key`, `summary`, `project`,
`token`, `host`, `caller`, `via`, `broker`, `created_at`, `expires_at`. The phone never
re-serialises it: `CanonicalApproval` parses the bytes it was given, refuses `v ≠ 1` and ops other
than `bws`/`save`, checks every displayed field equals the signed one, and signs those exact bytes.

**Pairing QR (§3.2).** `whispera-link://pair?v=1&url=<pct-encoded base URL>&code=<8 chars of
23456789ABCDEFGHJKMNPQRSTVWXYZ>&fp=<64-hex daemon fingerprint>`.

**Error envelope (§13).** Every non-2xx body is

```json
{"error":{"code":"auth_clock_skew","message":"…","type":"auth_error","server_time":1791158400}}
```

`type` follows from the status: 401/403/429 `auth_error`, 400/411/413/422
`invalid_request_error`, 404 `not_found_error`, 409/410 `conflict_error`, 502–504
`upstream_error`, otherwise `server_error`. Extra fields (`herdr_code`, `status`) sit beside the
four. `ErrorCode` lists all 32 codes with their statuses.

**Agreement key record (`kem_pubkey`).** The backend stores `kem_pubkey` as opaque standard
base64 (1–2048 decoded bytes). This package puts a `KEMKeyRecord` there: the 65-byte X9.63 P-256
agreement key followed by the device's link-key ECDSA DER signature over
`"WL1-KEM\n" ‖ x963`. A sender only seals to a key whose record verifies against the recipient's
link key (itself checked against `link_fp`), so a server that swaps `kem_pubkey` gets refused
(`RelayError.badKEMRecord`) instead of a readable message.

**Relay envelope `WLE1`.** What the relay stores and forwards, as standard base64 in the
`ciphertext` field. HPKE (RFC 9180) base mode, DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 /
AES-256-GCM (CryptoKit `HPKE.Ciphersuite.P256_SHA256_AES_GCM_256`), one seal per envelope, sealed
to the recipient's agreement key with `info = "whispera-link relay v1"`. Integers big-endian:

```
magic        4   "WLE1"
version      1   0x01
kem_id       2   0x0010
kdf_id       2   0x0001
aead_id      2   0x0002
sender_len   1   then sender device id (ASCII, 1–255 bytes)
recip_len    1   then recipient device id (ASCII, 1–255 bytes)
created_at   8   i64 Unix seconds
message_id  16   random
enc         65   HPKE encapsulated key (X9.63)
                 ^ everything above is the "header": the AEAD associated data
ct_len       4   u32, then ct: HPKE ciphertext (plaintext + 16-byte tag)
sig_len      2   u16, then sig: sender's link key, ECDSA DER, over
                 "WL1-SEAL\n" ‖ header ‖ ct_len ‖ ct
```

The recipient refuses, in order: an envelope addressed to another device (`wrongRecipient`), a
signature that does not verify with the sender's registered link key (`badSignature`), a
`created_at` more than 7 days old or 5 minutes ahead (`stale`), then anything HPKE will not open
(`openFailed`). The relay therefore sees two device ids, a time and a length, and can neither read,
forge, nor re-address a message: the ids are signed and are the AEAD's associated data. Sender
authenticity is the link-key signature rather than HPKE auth mode because the link key is already
the registered identity and the Secure Enclave signs without exporting it. Dropping duplicate
`message_id`s is the recipient's job; the relay's per-mailbox `seq` already gives at-most-once
delivery.

**Backend relay API** — the Rust server's routes (`whispera-backend` PR #4,
`crates/server/src/lib.rs`), which `RelayClient` calls and `Tests/WhisperaLinkTests/FakeRelay.swift`
mimics, status codes included:

| Call | Auth | Request | Response |
| --- | --- | --- | --- |
| `GET /v1/health` | none | — | `BackendHealth` |
| `POST /v1/devices` | `Authorization: Bearer <account token>` | `RegisterDeviceRequest` | `201 PublicDevice` |
| `GET /v1/devices` | account bearer | — | `DeviceList` |
| `DELETE /v1/devices/{id}` | account bearer | — | `204` |
| `GET /v1/device/peers` | WL1 | — | `DeviceList`, the caller's account |
| `POST /v1/relay/send` | WL1 | `RelaySendRequest` | `201 RelaySendResponse` |
| `GET /v1/relay/messages?after=&limit=&wait=` | WL1 | — | `RelayFetchResponse` |
| `POST /v1/relay/ack` | WL1 | `RelayAckRequest` | `RelayAckResponse` (`deleted`) |
| `GET /v1/relay/stream?after=` | WL1 | — | SSE: `event: message`, `id: <seq>`, `data: <RelayMessage>` |
| `POST /v1/notify` | WL1 | `NotifyRequest` | `NotifyResponse` |

`messages` with `wait > 0` is a long poll: answered at once when a message with `seq > after` is
queued, otherwise after up to `wait` seconds (server cap 30) with `{"messages":[]}`. Messages stay
until acked (`up_to_seq`, inclusive) or expired (default TTL 24 h, max 7 days); the server caps a
ciphertext at 64 KiB. Bodies are snake_case JSON; nil optionals are omitted from requests. WL1 is
verified over the request's `path_and_query`, exactly what `LinkCrypto.requestTarget(for:)` signs.
`NotifyRequest` adds optional `kind` (`approval` | `approval.resolved`), `request_id` and `sealed`
(a WLP1 blob, only with `approval`); without them it is the legacy content-free push.

**LinkAPI over the relay.** When the phone cannot reach the Mac directly, `RelayLinkTransport`
sends the same WL1-signed request as an `api_request` `LinkMessage` sealed to the Mac's account
device; the Mac answers with `api_response` frames, and `api_cancel` stops a stream. TTL 120 s.

```
{"type":"api_request","v":1,"id":"rq_<32 hex>","method":"GET","target":"/v1/agents?x=1",
 "headers":{"X-WL-Device":"dev_…","X-WL-Timestamp":"…","X-WL-Nonce":"…","X-WL-Signature":"…"},
 "body":"<std base64>","stream":false}
{"type":"api_response","v":1,"id":"rq_…","part":0,"status":200,"headers":{"Content-Type":"…"},
 "body":"<b64, ≤ 32 KiB raw>","final":false}
{"type":"api_response","v":1,"id":"rq_…","part":1,"body":"…","final":true}
{"type":"api_cancel","v":1,"id":"rq_…"}
```

Headers are whitelisted both ways (request: the four `X-WL-*`, `Content-Type`, `Accept`,
`Last-Event-ID`; response: `Content-Type`, `X-WL-Request-Id`, `X-WL-Server-Signature`,
`Retry-After`), matched case-insensitively and written in that spelling. The target is the signed
path + query, the host is dropped, so a relay-only `LinkClient` can sit on
`RelayAPI.placeholderBaseURL(macDeviceID:)` (`wl-relay://dev_…`). `RelayMailbox` is the one inbox
pump per device (long poll, ack after dispatch, cursor hooks) and routes `api_response` frames to
the waiting request — only from the Mac it was sent to. `FailoverLinkTransport` tries direct first,
moves to the relay on a connect-level error (never on an HTTP status), and re-probes
`GET /v1/health` every 30 s to move back. `RelayAPIStreamWriter` and `RelayAPIServerSupport` are the
Mac's side: frames out of a response, in order.

**WLP1 push sealing.** Named approval pushes carry their text sealed for the phone's Notification
Service Extension:

```
shared = ECDH(P-256, phone agreement key, Mac agreement key)   (the kem_pubkey keys)
key    = HKDF-SHA256(ikm: shared, salt: "WLP1", info: "whispera push v1|<phone id>|<mac id>", 32 B)
sealed = base64(nonce(12) ‖ AES-256-GCM ciphertext ‖ tag(16)),  AAD = "WLP1\n" + request_id
plain  = {"body":"…","request_id":"apr_…","title":"…"}   (sorted keys, ≤ 1 KiB)
```

`PushSealing` derives, seals and opens (the fixed vector in `PushAndAgentsTests` was computed
independently with Python `cryptography`); `PushKeyring` is the app-group `push-keys.json`
(Mac device id → base64 key) the extension reads.

### Parity with the Rust `whispera-proto` crate

Same vectors, same names. `Tests/WhisperaLinkTests/Resources/v1.json` is a verbatim copy of
`whispera-link/docs/vectors/v1.json`, the file `whispera-backend/crates/proto/tests/vectors.rs`
reads, and `ConformanceTests` mirrors that file test for test (`testRequestAuth` ↔ `request_auth`,
`testApproval` ↔ `approval`, …) plus the unit tests in `keys.rs`, `sign.rs` and `error.rs`.

| Swift | Rust |
| --- | --- |
| `LinkPublicKey` (`x963`, `spkiDER`, `spkiPEM`, `fingerprint`, `displayFingerprint`) | `keys::PublicKey` |
| `SoftwareSigningKey(pkcs8PEM:)` | `keys::SigningKey::from_pkcs8_pem` |
| `LinkKeyError` | `ProtoError` |
| `LinkCrypto.stringToSign`, `.pairProofMessage`, `.pairApproveMessage`, `.pairResponseMessage`, `.approvalMessage` | `sign::string_to_sign`, `pair_*_message`, `approval_message` |
| `LinkCrypto.verify` | `sign::verify_der_b64` |
| `SignedHeaders`, `.sign`, `.verify` | `sign::SignedHeaders`, `::sign`, `sign::verify_request` |
| `LinkCrypto.parseTimestamp`, `.isValidDeviceID`, `.isValidNonce`, `.newDeviceID`, `.makeNonce` | `sign::parse_timestamp`, `is_valid_*`, `new_device_id`, `new_nonce` |
| `ErrorCode`, `ErrorEnvelope`, `ErrorBody` | `error::ErrorCode`, `ErrorEnvelope`, `ErrorBody` |
| `Platform`, `ApnsEnv`, `ApnsRegistration`, `RegisterDeviceRequest`, `PublicDevice`, `DeviceList`, `Relay*` (incl. `RelayAckResponse`), `Notify*` | `wire::` same names |
| `BackendHealth` | `wire::Health` |

What the Rust side does not have, by design: the `WLE1` envelope and the `KEMKeyRecord` inside
`kem_pubkey` are end-to-end formats the server never opens — it validates only that both are
standard base64 within its size limits. A Linux daemon that wants to talk to a Swift device needs
both; the HPKE suite is pinned to the RFC 9180 test vector in
`Resources/hpke-rfc9180-p256-aes256.json`, which CryptoKit is tested against, so any implementation
passing the same vector interoperates.

## Porting notes

- **`NSPanel` is deliberately not shipped.** Putting a borderless, screen-saver-level panel on
  screen is host-application policy with no iOS equivalent. These views render into a surface you
  already own.
- `NSScreen` and `NSColor` are likewise absent. Colour crosses as SwiftUI `Color`, resolved through
  `Color.resolve(in:)` — iOS 17 / macOS 14, exactly this package's floor.
- `EdgeMagnetLayerView` is the one genuinely two-sided file: AppKit wants a backing layer, UIKit
  wants a `layerClass`. Everything above it is written once.
- The public API takes plain values only — a `Float`, an `[Float]`, a `Color`, a `CGRect`, a
  profile struct. No app singletons, no logger, no audio manager, no `@AppStorage`.

## Metal and SwiftPM

Shaders and tokens load from `Bundle.module`, never the host application's main bundle — a
`ShaderLibrary` or `makeDefaultLibrary()` resolved against the main bundle finds nothing here and
renders an empty screen with no error.

**`swift build` cannot compile Metal.** It copies the `.metal` sources and produces no
`default.metallib`, so the package builds and its logic tests, but nothing draws. Xcode's build
system compiles them properly:

```bash
xcodebuild -scheme WhisperaComponents -destination "platform=macOS" test
xcodebuild -scheme WhisperaComponents -destination "generic/platform=iOS" build
```

## Running the tests

From the repository root, not from `apple/` — that is where the manifest lives:

```bash
swift build                 # every target
swift run DictationSelfTest # 100 checks, no XCTest required
swift run PackageSelfTest   # 140 checks over OpenAI / Recipes / Backend, likewise
swift test                  # everywhere XCTest exists
```

`swift test` needs Xcode. **Command Line Tools ship no `XCTest.framework`** — and no swift-testing
module either — so on a CLT-only machine `swift test` cannot build *any* test target, including the
`WhisperaComponentsTests` that predate the dictation work. That is a property of the toolchain, not
of this package.

So the dictation assertions live in `Sources/DictationChecks`, as ordinary Swift, and two harnesses
run them: `DictationSelfTest`, an executable that works under CLT, and `WhisperaDictationTests`, a
thin XCTest wrapper for everywhere else. One source of truth, two harnesses — a check added to
`DictationChecks` shows up in both, and a test in `DictationChecksTests` fails if a group is renamed
without updating it.

`Sources/PackageChecks` is the same arrangement for `WhisperaOpenAI`, `WhisperaRecipes`,
`WhisperaBackend` and the granularity decoding, run by `PackageSelfTest` and `WhisperaPackageTests`.
Its HTTP checks answer from a `URLProtocol` stub keyed by a unique host per check, so nothing needs
a server and parallel checks cannot answer each other's requests.

`WhisperaLinkTests` and `WhisperaLinkServerTests` are plain XCTest targets with no CLT harness:
they need CryptoKit's HPKE, which is there wherever XCTest is. On an iOS Simulator:

```bash
xcodebuild test -scheme whispera-components-Package \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro Max" \
  -only-testing:WhisperaLinkTests -only-testing:WhisperaLinkServerTests
```

The checks need no network and no audio hardware: WAV cases build their own files in a temp
directory, and the socket sits behind `DictationTransport`, so the retry-once-on-401 behaviour is
stated in ten lines instead of needing a server that can be told to reject the first token.

## Where the constants come from

Nothing here spells a visual constant as a literal. Swift decodes `Resources/tokens.json` through
`WhisperaTokens.shared`, and the shaders include `Glow/GeneratedTokens.h` — both generated from
`tokens/tokens.json` at the repository root by `pnpm sync-tokens`. Tests fail if either goes stale,
or if a shader grows a hand-typed number back.

`WhisperaDictationUI` has a **third** copy, for the same reason the web packages have their own: a
SwiftPM resource cannot reach outside its target directory, and the alternative — depending on
`WhisperaComponents` — would make a dictation view require the Metal toolchain. It is generated by
the same script and held to the same contract: `pnpm check-tokens` fails if it drifts, and so does
the `UI › its tokens copy matches the source of truth` check, which compares the packaged bytes
against `tokens/tokens.json` rather than only the fields the Swift struct happens to model.

Scalars decode as `Double`, not `Float`, and narrow only at the GPU boundary: `float32` cannot
represent `0.82` exactly, and quantizing on the way in put the Swift maths ~6e-8 away from the
TypeScript port.
