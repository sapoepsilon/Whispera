#!/bin/bash
# Mac voice server check: a paired soft phone transcribes a spoken WAV through the helper's
# OpenAI-compatible POST /v1/audio/transcriptions (WL1-signed), answered by Whispera's own WhisperKit
# model, and the phone's bare STT bearer is refused (401 auth_missing).
#
#   LinkHelper/e2e/voice-server.sh <path to WhisperaLinkHelper binary>
#
# The binary must be a Debug build: a Release login item ignores every WHISPERA_LINK_* variable
# (HelperEnvironment), so it would use the real state directory and Whispera's own settings.
#
# The helper serves whatever engine is selected in Whispera; the script selects it in a throwaway
# preferences domain (WHISPERA_LINK_APP_DEFAULTS), never in the installed app's:
#   VOICE_ENGINE=whisperKit (default)            the on-device WhisperKit model
#   VOICE_ENGINE=realtimeDirect VOICE_SPEECH_URL=http://10.0.0.57:8000/v1 \
#     VOICE_SPEECH_MODEL=Systran/faster-distil-whisper-small.en   a speaches / OpenAI-compatible server
# Either way the phone sends a model the speech server does not have, which the Mac ignores.
#
# The soft phone is this package's link-soft-phone (pairing v2: commit, then reveal); it needs a
# WhisperKit model Whispera downloaded (WHISPERA_LINK_STT_MODEL, default openai_whisper-small), and
# /usr/bin/python3 with `cryptography` to sign the multipart requests. State lives in a temp dir and the helper
# binds 127.0.0.1 on a free port, so an installed helper or v1 daemon is never touched.
set -euo pipefail

HELPER="${1:?usage: voice-server.sh <WhisperaLinkHelper binary>}"
PACKAGE="$(cd "$(dirname "$0")/.." && pwd)"
PY=/usr/bin/python3
(cd "$PACKAGE" && swift build --product link-soft-phone >&2)
PHONE_BIN="$(cd "$PACKAGE" && swift build --product link-soft-phone --show-bin-path)/link-soft-phone"
T="$(mktemp -d /tmp/wlvoice.XXXXXX)"
PIDS=()
cleanup() {
  local rc=$?
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [ $rc -ne 0 ] && { echo "--- helper output"; tail -20 "$T/helper.out"; echo "--- helper log"; tail -20 "$T/helper.log"; }
  defaults delete "$WHISPERA_LINK_APP_DEFAULTS" >/dev/null 2>&1 || true
  rm -rf "$T"
  exit $rc
}
trap cleanup EXIT
wait_for() { local end=$(( $(date +%s) + $1 )); while ! eval "$2"; do [ "$(date +%s)" -ge "$end" ] && { echo "FAIL timeout: $2"; return 1; }; sleep 0.2; done; }

export WHISPERA_LINK_HOME="$T/state" WHISPERA_LINK_CONFIG="$T/config.json" WHISPERA_LINK_LOG="$T/helper.log"
export WHISPERA_LINK_BONJOUR=0 WHISPERA_LINK_XPC=0 WHISPERA_LINK_BWS_TOUCHID=""
export WHISPERA_LINK_STT_MODEL="${WHISPERA_LINK_STT_MODEL:-openai_whisper-small}"
VOICE_ENGINE="${VOICE_ENGINE:-whisperKit}"
export WHISPERA_LINK_APP_DEFAULTS="test.whispera.link.e2e.$$"
defaults write "$WHISPERA_LINK_APP_DEFAULTS" whisperaTranscriptionEngine -string "$VOICE_ENGINE"
defaults write "$WHISPERA_LINK_APP_DEFAULTS" whisperaTranscriptionDirectURL -string "${VOICE_SPEECH_URL:-}"
defaults write "$WHISPERA_LINK_APP_DEFAULTS" whisperaTranscriptionDirectModel -string "${VOICE_SPEECH_MODEL:-}"
PHONE_MODEL="Systran/faster-whisper-large-v3"
if [ "$VOICE_ENGINE" = whisperKit ]; then EXPECT_MODE=local; else EXPECT_MODE=remote; fi
PORT=$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
printf '{"listen_host": "127.0.0.1", "port": %s, "herdr_socket": "%s/no-herdr.sock"}\n' "$PORT" "$T" > "$WHISPERA_LINK_CONFIG"

"$HELPER" serve > "$T/helper.out" 2>&1 &
PIDS+=($!)
wait_for 15 'grep -q listening "$T/helper.out"'
URL="http://127.0.0.1:$PORT"

QR=$("$PY" - "$WHISPERA_LINK_HOME/admin.sock" <<'PYEOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(b'{"op":"pair.begin","ttl_s":60}\n')
data = b""
while not data.endswith(b"\n"):
    data += s.recv(65536)
print(json.loads(data)["qr_payload"])
PYEOF
)
"$PHONE_BIN" pair --state "$T/phone" --qr "$QR" > "$T/paired.json"
echo "ok   soft phone paired (pairing v2)"
# Unsigned health is the pre-pairing minimum; the speech status comes with a signed one.
"$PHONE_BIN" call --state "$T/phone" GET /v1/health > "$T/health.json"
"$PY" -c 'import json,sys; h=json.load(open(sys.argv[1]))["json"]; assert h["stt"]=="configured" and h["stt_mode"]==sys.argv[2], h; print("ok   health (WL1): stt configured, mode %s" % sys.argv[2])' "$T/health.json" "$EXPECT_MODE"
KEY=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["stt_key"])' "$T/phone/phone.json")

# The speech routes are WL1-signed like every other route. link-soft-phone `call` only sends JSON,
# so multipart requests are signed here with the phone's saved link key (stringToSign, WL1 §4.2).
cat > "$T/wl1.py" <<'PYEOF'
import base64, hashlib, json, os, sys, time, urllib.error, urllib.request, uuid
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

def main():
    state, method, target = sys.argv[1], sys.argv[2], sys.argv[3]
    fields = dict(a.split("=", 1) for a in sys.argv[4:] if not a.startswith("@"))
    files = [a[1:] for a in sys.argv[4:] if a.startswith("@")]
    phone = json.load(open(os.path.join(state, "phone.json")))
    key = serialization.load_pem_private_key(phone["link_key_pem"].encode(), password=None)
    body, headers = b"", {}
    if fields or files:
        boundary = "wl1-" + uuid.uuid4().hex
        parts = []
        for name, value in fields.items():
            parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (boundary, name, value)).encode())
        for path in files:
            head = '--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\nContent-Type: audio/wav\r\n\r\n' % (boundary, os.path.basename(path))
            parts.append(head.encode() + open(path, "rb").read() + b"\r\n")
        body = b"".join(parts) + ("--%s--\r\n" % boundary).encode()
        headers["Content-Type"] = "multipart/form-data; boundary=" + boundary
    ts = str(int(time.time()))
    nonce = base64.urlsafe_b64encode(os.urandom(16)).rstrip(b"=").decode()
    device = phone["device_id"]
    message = "\n".join(["WL1", method.upper(), target, hashlib.sha256(body).hexdigest(), ts, nonce, device])
    signature = key.sign(message.encode(), ec.ECDSA(hashes.SHA256()))
    headers.update({"X-WL-Device": device, "X-WL-Timestamp": ts, "X-WL-Nonce": nonce,
                    "X-WL-Signature": base64.b64encode(signature).decode()})
    request = urllib.request.Request(phone["base_url"] + target, data=body if method == "POST" else None,
                                     headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            status, data = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, data = error.code, error.read()
    sys.stderr.write("status %d\n" % status)
    sys.stdout.buffer.write(data)
    sys.exit(0 if status == 200 else 1)

main()
PYEOF
wl1() { "$PY" "$T/wl1.py" "$T/phone" "$@"; }

for target in /v1/models /v1/audio/transcriptions; do
  if [ "$target" = /v1/models ]; then
    curl -s -o "$T/bearer.json" -w '%{http_code}' -H "Authorization: Bearer $KEY" "$URL$target" > "$T/bearer.status"
  else
    say -o "$T/probe.aiff" "probe" && afconvert -f WAVE -d LEI16@16000 -c 1 "$T/probe.aiff" "$T/probe.wav"
    curl -s -o "$T/bearer.json" -w '%{http_code}' -H "Authorization: Bearer $KEY" -F "model=$PHONE_MODEL" \
      -F "file=@$T/probe.wav" "$URL$target" > "$T/bearer.status"
  fi
  "$PY" - "$T/bearer.status" "$T/bearer.json" "$target" <<'PYEOF'
import json, sys
status = open(sys.argv[1]).read().strip()
code = json.load(open(sys.argv[2])).get("error", {}).get("code")
assert status == "401" and code == "auth_missing", (status, code)
print("ok   %s with the phone's own wlk_ key as a bare bearer -> 401 auth_missing" % sys.argv[3])
PYEOF
done

wl1 GET /v1/models > "$T/models.json"
"$PY" - "$T/models.json" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
ids = [m["id"] for m in r["data"]]
assert ids == ["whispera-mac"] and r["data"][0]["ready"] is True, r
assert r["data"][0]["task"] == "automatic-speech-recognition"
print("ok   GET /v1/models (WL1) -> %s, engine %r" % (ids, r["data"][0]["engine"]))
PYEOF

SENTENCE="The quick brown fox jumps over the lazy dog."
say -o "$T/fox.aiff" "$SENTENCE"
afconvert -f WAVE -d LEI16@16000 -c 1 "$T/fox.aiff" "$T/fox.wav"
echo "ok   generated $(wc -c < "$T/fox.wav" | tr -d ' ') byte WAV with say: \"$SENTENCE\""

START=$("$PY" -c 'import time; print(time.time())')
wl1 POST /v1/audio/transcriptions "model=$PHONE_MODEL" "@$T/fox.wav" > "$T/stt.json"
"$PY" - "$T/stt.json" "$START" <<'PYEOF'
import json, re, sys, time
r = json.load(open(sys.argv[1]))
text = r.get("text", "")
words = re.sub(r"[^a-z ]", "", text.lower()).split()
assert {"quick", "brown", "fox", "lazy", "dog"} <= set(words), r
print("ok   POST /v1/audio/transcriptions (WL1) -> %r in %.1f s" % (text, time.time() - float(sys.argv[2])))
PYEOF

wl1 POST /v1/audio/transcriptions "model=$PHONE_MODEL" response_format=text "@$T/fox.wav" > "$T/text.txt"
grep -qi "brown fox" "$T/text.txt" || { echo "FAIL text format"; cat "$T/text.txt"; exit 1; }
echo "ok   signed multipart, response_format=text -> $(tr -d '\n' < "$T/text.txt")"

if grep -qi "quick brown" "$T/helper.log"; then echo "FAIL transcript text in the helper log"; exit 1; fi
echo "ok   no transcript text in the helper log"
echo
echo "VOICE SERVER PASS"
