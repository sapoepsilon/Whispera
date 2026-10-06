#!/bin/bash
# Mac voice server check: a paired soft phone transcribes a spoken WAV through the helper's
# OpenAI-compatible POST /v1/audio/transcriptions, answered by Whispera's own WhisperKit model.
#
#   LinkHelper/e2e/voice-server.sh <path to WhisperaLinkHelper binary>
#
# Needs a whispera-link checkout for the soft phone and the pairing CLI (WHISPERA_LINK_REPO,
# default ../whispera-link next to this repo) and a WhisperKit model Whispera downloaded
# (WHISPERA_LINK_STT_MODEL, default openai_whisper-small). State lives in a temp dir and the helper
# binds 127.0.0.1 on a free port, so an installed helper or v1 daemon is never touched.
set -euo pipefail

HELPER="${1:?usage: voice-server.sh <WhisperaLinkHelper binary>}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WL="${WHISPERA_LINK_REPO:-$(dirname "$REPO_ROOT")/whispera-link}"
PY=/usr/bin/python3
PHONE_PY="$WL/tests/fakes/soft_phone.py"
[ -f "$PHONE_PY" ] || { echo "FAIL no whispera-link checkout at $WL"; exit 1; }
T="$(mktemp -d /tmp/wlvoice.XXXXXX)"
PIDS=()
cleanup() {
  local rc=$?
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [ $rc -ne 0 ] && { echo "--- helper output"; tail -20 "$T/helper.out"; echo "--- helper log"; tail -20 "$T/helper.log"; }
  rm -rf "$T"
  exit $rc
}
trap cleanup EXIT
wait_for() { local end=$(( $(date +%s) + $1 )); while ! eval "$2"; do [ "$(date +%s)" -ge "$end" ] && { echo "FAIL timeout: $2"; return 1; }; sleep 0.2; done; }

export WHISPERA_LINK_HOME="$T/state" WHISPERA_LINK_CONFIG="$T/config.json" WHISPERA_LINK_LOG="$T/helper.log"
export WHISPERA_LINK_BONJOUR=0 WHISPERA_LINK_XPC=0 WHISPERA_LINK_BWS_TOUCHID=""
export WHISPERA_LINK_STT_MODEL="${WHISPERA_LINK_STT_MODEL:-openai_whisper-small}"
PORT=$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
printf '{"listen_host": "127.0.0.1", "port": %s, "herdr_socket": "%s/no-herdr.sock"}\n' "$PORT" "$T" > "$WHISPERA_LINK_CONFIG"

"$HELPER" serve > "$T/helper.out" 2>&1 &
PIDS+=($!)
wait_for 15 'grep -q listening "$T/helper.out"'
URL="http://127.0.0.1:$PORT"
curl -s "$URL/v1/health" > "$T/health.json"
"$PY" -c 'import json,sys; h=json.load(open(sys.argv[1])); assert h["stt"]=="configured" and h["stt_mode"]=="local", h; print("ok   health: stt configured, mode local")' "$T/health.json"

"$WL/bin/whispera-link" pair --json --ttl 60 > "$T/pair.out" 2>&1 &
PAIR=$!
wait_for 5 'grep -q qr_payload "$T/pair.out"'
QR=$("$PY" -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["qr_payload"])' "$T/pair.out")
PHONE="$PY $PHONE_PY --state $T/phone"
$PHONE pair --qr "$QR" > "$T/paired.json"
wait "$PAIR"
echo "ok   soft phone paired"
KEY=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["stt_key"])' "$T/phone/phone.json")

$PHONE call GET /v1/models --stt-bearer > "$T/models.json"
"$PY" - "$T/models.json" "$WHISPERA_LINK_STT_MODEL" <<'PYEOF'
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
ids = [m["id"] for m in r["json"]["data"]]
assert r["status"] == 200 and ids == ["whisper-1", sys.argv[2]], r
assert all(m["task"] == "automatic-speech-recognition" for m in r["json"]["data"])
print("ok   GET /v1/models -> %s" % ids)
PYEOF

SENTENCE="The quick brown fox jumps over the lazy dog."
say -o "$T/fox.aiff" "$SENTENCE"
afconvert -f WAVE -d LEI16@16000 -c 1 "$T/fox.aiff" "$T/fox.wav"
echo "ok   generated $(wc -c < "$T/fox.wav" | tr -d ' ') byte WAV with say: \"$SENTENCE\""

START=$("$PY" -c 'import time; print(time.time())')
$PHONE stt "$T/fox.wav" > "$T/stt.json"
"$PY" - "$T/stt.json" "$START" <<'PYEOF'
import json, re, sys, time
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
text = r["json"]["text"] if isinstance(r.get("json"), dict) else ""
words = re.sub(r"[^a-z ]", "", text.lower()).split()
assert r["status"] == 200 and {"quick", "brown", "fox", "lazy", "dog"} <= set(words), r
print("ok   POST /v1/audio/transcriptions (soft phone, Bearer wlk_…) -> %r in %.1f s" % (text, time.time() - float(sys.argv[2])))
PYEOF

curl -s -H "Authorization: Bearer $KEY" -F model=whisper-1 -F response_format=text -F "file=@$T/fox.wav" \
  "$URL/v1/audio/transcriptions" > "$T/curl.txt"
grep -qi "brown fox" "$T/curl.txt" || { echo "FAIL curl text format"; cat "$T/curl.txt"; exit 1; }
echo "ok   curl multipart, response_format=text -> $(tr -d '\n' < "$T/curl.txt")"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wlk_wrong" -F model=whisper-1 -F "file=@$T/fox.wav" "$URL/v1/audio/transcriptions")
[ "$STATUS" = 401 ] || { echo "FAIL wrong key gave $STATUS"; exit 1; }
echo "ok   wrong wlk_ key -> 401"
if grep -qi "quick brown" "$T/helper.log"; then echo "FAIL transcript text in the helper log"; exit 1; fi
echo "ok   no transcript text in the helper log"
echo
echo "VOICE SERVER PASS"
