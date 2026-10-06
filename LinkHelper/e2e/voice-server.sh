#!/bin/bash
# Mac voice server check: a paired soft phone transcribes a spoken WAV through the helper's
# OpenAI-compatible POST /v1/audio/transcriptions, answered by Whispera's own WhisperKit model.
#
#   LinkHelper/e2e/voice-server.sh <path to WhisperaLinkHelper binary>
#
# The helper serves whatever engine is selected in Whispera; the script selects it in a throwaway
# preferences domain (WHISPERA_LINK_APP_DEFAULTS), never in the installed app's:
#   VOICE_ENGINE=whisperKit (default)            the on-device WhisperKit model
#   VOICE_ENGINE=realtimeDirect VOICE_SPEECH_URL=http://192.168.50.140:8000/v1 \
#     VOICE_SPEECH_MODEL=Systran/faster-distil-whisper-small.en   a speaches / OpenAI-compatible server
# Either way the phone sends a model the speech server does not have, which the Mac ignores.
#
# The soft phone is this package's link-soft-phone (pairing v2: commit, then reveal); it needs a
# WhisperKit model Whispera downloaded (WHISPERA_LINK_STT_MODEL, default openai_whisper-small). State lives in a temp dir and the helper
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
curl -s "$URL/v1/health" > "$T/health.json"
"$PY" -c 'import json,sys; h=json.load(open(sys.argv[1])); assert h["stt"]=="configured" and h["stt_mode"]==sys.argv[2], h; print("ok   health: stt configured, mode %s" % sys.argv[2])' "$T/health.json" "$EXPECT_MODE"

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
KEY=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["stt_key"])' "$T/phone/phone.json")

curl -s -H "Authorization: Bearer $KEY" "$URL/v1/models" > "$T/models.json"
"$PY" - "$T/models.json" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
ids = [m["id"] for m in r["data"]]
assert ids == ["whispera-mac"] and r["data"][0]["ready"] is True, r
assert r["data"][0]["task"] == "automatic-speech-recognition"
print("ok   GET /v1/models -> %s, engine %r" % (ids, r["data"][0]["engine"]))
PYEOF

SENTENCE="The quick brown fox jumps over the lazy dog."
say -o "$T/fox.aiff" "$SENTENCE"
afconvert -f WAVE -d LEI16@16000 -c 1 "$T/fox.aiff" "$T/fox.wav"
echo "ok   generated $(wc -c < "$T/fox.wav" | tr -d ' ') byte WAV with say: \"$SENTENCE\""

START=$("$PY" -c 'import time; print(time.time())')
curl -s -H "Authorization: Bearer $KEY" -F "model=$PHONE_MODEL" -F "file=@$T/fox.wav" "$URL/v1/audio/transcriptions" > "$T/stt.json"
"$PY" - "$T/stt.json" "$START" <<'PYEOF'
import json, re, sys, time
r = json.load(open(sys.argv[1]))
text = r.get("text", "")
words = re.sub(r"[^a-z ]", "", text.lower()).split()
assert {"quick", "brown", "fox", "lazy", "dog"} <= set(words), r
print("ok   POST /v1/audio/transcriptions (Bearer wlk_…) -> %r in %.1f s" % (text, time.time() - float(sys.argv[2])))
PYEOF

curl -s -H "Authorization: Bearer $KEY" -F "model=$PHONE_MODEL" -F response_format=text -F "file=@$T/fox.wav" \
  "$URL/v1/audio/transcriptions" > "$T/curl.txt"
grep -qi "brown fox" "$T/curl.txt" || { echo "FAIL curl text format"; cat "$T/curl.txt"; exit 1; }
echo "ok   curl multipart, response_format=text -> $(tr -d '\n' < "$T/curl.txt")"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wlk_wrong" -F "model=$PHONE_MODEL" -F "file=@$T/fox.wav" "$URL/v1/audio/transcriptions")
[ "$STATUS" = 401 ] || { echo "FAIL wrong key gave $STATUS"; exit 1; }
echo "ok   wrong wlk_ key -> 401"
if grep -qi "quick brown" "$T/helper.log"; then echo "FAIL transcript text in the helper log"; exit 1; fi
echo "ok   no transcript text in the helper log"
echo
echo "VOICE SERVER PASS"
