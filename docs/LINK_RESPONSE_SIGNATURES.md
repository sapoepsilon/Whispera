# Link response signatures (WL1-RESP)

The phone signs every request to the Mac helper (WL1, PROTOCOL §4). On the relay every
answer is sealed to the phone too, but a direct connection is plain HTTP: over Tailscale
WireGuard protects it, and with "Allow unencrypted local network connections" on
(`allow_lan_http` in the link offer) anyone on the LAN can rewrite what the helper answers.
WL1-RESP signs those answers with the daemon key, so a client can tell a response, or an
event in a stream, came unchanged from the Mac it paired with.

The helper signs every response it sends on a direct HTTP connection, whatever the peer
(loopback, tailnet or LAN). Relayed responses (`api_response` frames) are not signed this
way; the relay already seals them. Everything here is additive: existing bodies, fields and
headers are unchanged, and clients that do not know WL1-RESP ignore the extra headers and the
extra SSE field.

Implementation: `LinkHelper/Sources/LinkHelperCore/ResponseSignature.swift`
(`ResponseSigner`, `SSEEventSigner`), applied in `HTTPExchange.respond`, `beginStream` and
`write` (`HTTPServer.swift`).

## Key

The daemon key: the helper's P-256 signing key in `daemon_key.pem`, the same key that signs
the pairing acknowledgement and response (`X-WL-Server-Signature`, PROTOCOL §3.3). The phone
pins it at pairing: the pair responses carry `daemon_pubkey` (standard base64 of the 65-byte
X9.63 point) and the phone checks its SHA-256 against `daemon_fp`, which it already knows from
the QR code, the link offer or `GET /v1/health`.

Signatures are ECDSA P-256 with SHA-256, ASN.1 DER, standard base64 with padding — the same
encoding as `X-WL-Signature` and `X-WL-Server-Signature`. Verify with
`LinkCrypto.verify(x963:message:signatureBase64:)`.

## Complete responses

Two response headers:

```
X-WL-Response-Timestamp: <ts>
X-WL-Response-Signature: <base64 DER signature>
```

`ts` is the helper's clock in decimal Unix seconds when it signed. The signed message is seven
fields joined by `\n` (0x0A), no trailing newline:

```
WL1-RESP
<ts>
<nonce>
<METHOD>
<target>
<status>
<sha256hex(body)>
```

- `WL1-RESP`: scheme and version tag. No other message the daemon key signs starts with it
  (`WL1-PAIR-RESP`, `WL1-PAIR-COMMIT-ACK` and `WL1-RESP-EVENT` all differ in the first line).
- `nonce`: the request's `X-WL-Nonce`, when it is a well-formed nonce
  (`^[A-Za-z0-9_-]{22}$`); otherwise the empty string. See "Requests without a nonce".
- `METHOD`: the request method, ASCII-uppercased (`GET`, `POST`).
- `target`: the request target exactly as it arrived on the request line (path plus `?query`,
  percent-encoding untouched) — the same string WL1 signs.
- `status`: the HTTP status as decimal (`200`, `401`).
- `sha256hex(body)`: lowercase hex SHA-256 of the exact body bytes sent (for `HEAD`, of the
  empty body: `e3b0c442…b855`).

In `nonce`, `METHOD` and `target`, every byte of the UTF-8 field that is `%` (0x25) or outside
visible ASCII (0x21–0x7E) is written as `%XX` (two uppercase hex digits); every other byte is
copied. So no field can contain the separator, and the encoding is one-to-one: a target with a
literal `%0A` signs as `%250A`, one with a newline as `%0A`. This applies to a percent-encoded
target too: `/v1/agents/tmux%3Ap1` signs as `/v1/agents/tmux%253Ap1`. A client applies the same
encoding to the target it sent (byte for byte, after nothing else) before it verifies.

A client verifies:

1. Both headers are present; `ts` parses as decimal seconds.
2. The signature verifies with the pinned daemon key over the message built from the request
   it sent (its own nonce, method and target) and the status and body it received.
3. `|now − ts|` is within the clock skew it already tolerates for requests (60 s), after the
   offset it learned from `server_time`.

A response that fails any step is treated as a transport failure, never as the helper's
answer.

## Streams (SSE)

`GET /v1/events` and `GET /v1/agents/{id}/terminal` answer `text/event-stream`. The response
head carries the same two headers, with the literal `stream` in place of the body hash:

```
WL1-RESP\n<ts>\n<nonce>\nGET\n<target>\n200\nstream
```

Then every event that has at least one non-comment line gets one more field as its last line,
just before the blank line that ends it:

```
event: approval.pending
id: 42
data: {"request_id":"apr_…","expires_at":1700000060}
wl-sig: <seq> <ts> <base64 DER signature>

```

`wl-sig` is an SSE field no parser knows, so it is ignored (WHATWG §9.2.6; `LinkSSEParser`
does the same). Its value is three fields separated by one space:

- `seq`: 1 for the first signed event of this response, then +1 per signed event.
- `ts`: decimal Unix seconds when that event was signed.
- the signature over:

```
WL1-RESP-EVENT
<ts>
<nonce>
<seq>
<sha256hex(event bytes)>
```

joined by `\n`, no trailing newline. `event bytes` are the event's lines exactly as sent, each
with its terminating `\n`, from its first byte up to (not including) the `wl-sig:` line. For the
example above: `event: approval.pending\nid: 42\ndata: {…}\n`. `nonce` is the stream request's
nonce, encoded as above.

A client keeps the raw bytes of each event, splits off the `wl-sig` line, and checks the
signature and that `seq` is exactly one more than the last event it accepted. A gap, a repeat or
a reorder means events were dropped, replayed or shuffled: drop the stream and reconnect (with
`Last-Event-ID` for `/v1/events`). Signatures over the same nonce never verify for another
stream, so events cannot be spliced in from another response.

Comment-only events (the `: ping` keep-alives) carry no `wl-sig` and take no `seq`; they hold
no data.

Events never contain a carriage return (0x0D). SSE parsers end a line at `\r`, `\n` or `\r\n`,
so a CR would let the lines a client sees differ from the bytes that were signed; the helper's
events are `event:`, `id:` and `data:` lines with fixed event names, decimal ids and `data` that
is either JSON (`JSONSerialization` escapes a CR inside a string as `\r`) or base64, and
`ResponseSignatureTests.testEventsNeverContainACarriageReturn` holds it. A client may treat any
CR in a signed stream as a failure. The `hello` event is the first signed event (`seq` 1) of `/v1/events`. The
safety-critical notifications (`approval.pending`, `approval.resolved`, `agent.permission`,
`agent.ask`) arrive as ordinary events, so each is signed, as are `resync` and the rest. The
permission, ask, dialog and approval payloads themselves (`GET /v1/agents/{id}/permission`,
`/ask`, `/dialog`, `/v1/permissions`, `/v1/asks`, `/v1/approvals/…`) are complete responses. Terminal frames (`event: frame`, `id: <position>`,
base64 data) are signed one by one.

## Requests without a nonce

A response is signed even when the request had no valid WL1 nonce: an unsigned
`GET /v1/health`, the pairing routes, a request refused with `auth_missing`. The `nonce` field
is then empty. Such a signature proves the Mac produced that status and body for that method and
target, but not for this particular request: a recorded answer could be replayed within its
timestamp's freshness window. A client that wants an unsigned response bound to its request may
send an `X-WL-Nonce` header with a fresh nonce on it; the helper binds any well-formed nonce, and
the header does not make the request a signed one.

Refusals are signed too: `401` (`auth_bad_signature`, `auth_replay`, `auth_clock_skew`, …),
`403` (`device_unconfirmed`), `404`, `429` and `5xx`, bound to the request's nonce when it carried
a well-formed one. A WL1 signature that did not verify does not stop the helper signing its
refusal with the nonce the request claimed; the client compares it with its own nonce, so a
refusal for someone else's request does not verify.

## What is not signed

- The terminal WebSocket (`GET /v1/agents/{id}/terminal/ws`): neither the `101` handshake
  nor its frames. It is only served on loopback and the tailnet, never on a plain local
  network, where the client uses the signed SSE terminal instead.
- Comment-only SSE events (`: ping`).
- Connections closed without any response: a refused peer, a malformed or slow request head,
  a request whose phone went away.
- The bare `503` sent, before any request byte is read, to a connection over the per-peer
  (16) or total (128) connection cap.
- `100 Continue` interim responses.
- Response headers other than the status: `Content-Type`, `X-WL-Request-Id` and the rest are
  outside the message.
- Responses over the relay (sealed `api_response` frames instead).

## Compatibility

A helper that signs lists `response_signatures` in the `capabilities` of the signed
`GET /v1/health`. A helper that does not sign sends neither header. A client should require
WL1-RESP from a helper that advertises it (and remember that per paired Mac, so a downgrade
on the LAN is noticed), and treat it as optional for older helpers.
