#!/bin/bash
# A standalone helper for the account-pairing e2e (step 11): no app, no XPC, no Bonjour, its own
# temp config and state, a non-default port — the installed helper and its state are never touched.
#
#   LinkHelper/e2e/account-pairing.sh serve            # build link-helper-serve and run it (foreground)
#   LinkHelper/e2e/account-pairing.sh admin '<json>'   # one admin-socket request, prints the JSON reply
#   LinkHelper/e2e/account-pairing.sh env              # print the environment `serve` uses
#   LinkHelper/e2e/account-pairing.sh pair-code        # start code pairing: code, Mac fingerprint, QR payload
#   LinkHelper/e2e/account-pairing.sh phone pair [--yes]   # a software phone pairs with the live code
#                                                      # (pairing v2: commit, signed ack, then reveal);
#                                                      # without --qr it compares the fingerprint on stdin
#   LinkHelper/e2e/account-pairing.sh phone call GET /v1/devices/me   # a WL1-signed call as that phone
#   LinkHelper/e2e/account-pairing.sh herdr '<json>'   # control request to the fake herdr (WLH_FAKE_HERDR=1)
#   LinkHelper/e2e/account-pairing.sh herdr-remote '<json>'   # … to the fake remote machine's herdr
#   LinkHelper/e2e/account-pairing.sh herdr-requests   # every request both fakes and the fake CLI received
#
# Environment (all optional):
#   WLH_E2E_DIR       state/config/log directory      default /tmp/wlh-account-e2e
#   WLH_PORT          helper HTTP port                default 17797
#   WLH_LISTEN        listen host                     default 127.0.0.1 (offers advertise http://127.0.0.1:PORT)
#   WLH_BACKEND_URL   account backend + relay         default http://127.0.0.1:18080
#   WLH_BEARER        account bearer to join with at start (e.g. `whispera-dev-idp mint alice`);
#                     without it, join later with:  admin '{"op":"account.set","bearer":"…","backend_url":"…"}'
#   WLH_POLL_S        relay long-poll wait, seconds   default 1
#   WLH_MAC_NAME      name the phone shows            default "E2E Mac"
#   WLH_TEST_CONFIRM  1 = allow admin '{"op":"approve.confirm","device_id":"dev_…","safety_number":"…"}'
#                     (test only, debug builds only; the app confirms with Touch ID over XPC)  default 1
#   WLH_FAKE_HERDR    1 = run fake herdr servers and the fake herdr CLI (e2e/fake_herdr.py,
#                     e2e/fake-herdr-cli): this Mac's herdr ($WLH_E2E_DIR/herdr.sock), one remote
#                     machine "fake-main" ("Fake Main Mac", $WLH_E2E_DIR/remote.sock) and one
#                     unreachable machine "fake-dead". Without it the helper has no herdr at all.
#                     The real herdr is never used.                       default 0
#   WLH_FAKE_AGENTS   N = each fake herdr (this Mac and fake-main) serves N generated agents with
#                     long titles and cwds instead of its 3/2 preset agents (WLH_FAKE_HERDR=1)
#   WLH_APPROVAL_FALLBACK_S  seconds before the other iPhones are pushed  default 20 (helper default)
#   WLH_REMOTE_POLL_S seconds between remote-machine status polls        default 10 (helper default)
#   WLH_OFFER_BASE_URLS  comma-separated base URLs the link offer advertises instead of the listener
#   WLH_RELAY_ONLY    1 = advertise only http://192.0.2.1:9 (unreachable TEST-NET address), so the
#                     phone can only reach this helper through the relay  default 0
#
# Admin ops (one JSON object per call):
#   {"op":"account.set","bearer":"…","backend_url":"…"}  join the account (registers the Mac once)
#   {"op":"account.status"}                               device_id, phones, last sync, pending confirmations
#   {"op":"account.sync"}                                 sync now: pinned / offered / dropped device ids
#   {"op":"account.clear"}                                leave the account (sends `unpaired` to the phones)
#   {"op":"approve.pending"}                              iPhones waiting for confirmation, each with its
#                                                         safety_number and key_changed
#   {"op":"approve.confirm","device_id":"dev_…","safety_number":"1234 5678 9012"}
#                                                         test only, needs WLH_TEST_CONFIRM=1; refused with
#                                                         keys_changed unless the number matches the keys now
#   {"op":"pair.begin","ttl_s":300}                       a pairing code (pair-code wraps it)
#   {"op":"devices.list"} / {"op":"status"}               as for any helper
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${WLH_E2E_DIR:-/tmp/wlh-account-e2e}"
PORT="${WLH_PORT:-17797}"
LISTEN="${WLH_LISTEN:-127.0.0.1}"
BACKEND="${WLH_BACKEND_URL:-http://127.0.0.1:18080}"

helper_env() {
  export WHISPERA_LINK_HOME="$DIR/state"
  export WHISPERA_LINK_CONFIG="$DIR/config.json"
  export WHISPERA_LINK_LOG="$DIR/helper.log"
  export WHISPERA_LINK_BONJOUR=0
  export WHISPERA_LINK_XPC=0
  export WHISPERA_LINK_RELAY_BASE_URL="$BACKEND"
  export WHISPERA_LINK_ACCOUNT_BACKEND_URL="$BACKEND"
  export WHISPERA_LINK_ACCOUNT_POLL_S="${WLH_POLL_S:-1}"
  export WHISPERA_LINK_MAC_NAME="${WLH_MAC_NAME:-E2E Mac}"
  if [ "${WLH_TEST_CONFIRM:-1}" = 1 ]; then export WHISPERA_LINK_TEST_ADMIN_CONFIRM=1; fi
  if [ -n "${WLH_BEARER:-}" ]; then export WHISPERA_LINK_ACCOUNT_BEARER="$WLH_BEARER"; fi
  if [ -n "${WLH_APPROVAL_FALLBACK_S:-}" ]; then export WHISPERA_LINK_APPROVAL_FALLBACK_S="$WLH_APPROVAL_FALLBACK_S"; fi
  if [ -n "${WLH_REMOTE_POLL_S:-}" ]; then export WHISPERA_LINK_REMOTE_POLL_S="$WLH_REMOTE_POLL_S"; fi
  if [ "${WLH_RELAY_ONLY:-0}" = 1 ]; then
    export WHISPERA_LINK_OFFER_BASE_URLS="http://192.0.2.1:9"
  elif [ -n "${WLH_OFFER_BASE_URLS:-}" ]; then
    export WHISPERA_LINK_OFFER_BASE_URLS="$WLH_OFFER_BASE_URLS"
  fi
  if [ "${WLH_FAKE_HERDR:-0}" = 1 ]; then
    export WHISPERA_LINK_HERDR_CLI="$DIR/herdr-cli"
  else
    export WHISPERA_LINK_HERDR_CLI=""
  fi
}

HERDR_SOCKET() { if [ "${WLH_FAKE_HERDR:-0}" = 1 ]; then echo "$DIR/herdr.sock"; else echo "$DIR/no-herdr.sock"; fi; }

# The fake herdr servers and CLI config; their PIDs go to $DIR/fake-herdr.pids.
start_fake_herdr() {
  local e2e="$HERE/e2e"
  rm -f "$DIR/herdr.sock" "$DIR/remote.sock" "$DIR/herdr-requests.jsonl" "$DIR/remote-requests.jsonl" "$DIR/herdr-cli.jsonl"
  local many_local=() many_remote=()
  if [ -n "${WLH_FAKE_AGENTS:-}" ]; then
    many_local=(--agents "$WLH_FAKE_AGENTS")
    many_remote=(--agents "$WLH_FAKE_AGENTS" --prefix r)
  fi
  /usr/bin/python3 "$e2e/fake_herdr.py" --socket "$DIR/herdr.sock" ${many_local[@]+"${many_local[@]}"} --record "$DIR/herdr-requests.jsonl" > "$DIR/fake-herdr.out" 2>&1 &
  echo $! > "$DIR/fake-herdr.pids"
  /usr/bin/python3 "$e2e/fake_herdr.py" --socket "$DIR/remote.sock" --preset remote ${many_remote[@]+"${many_remote[@]}"} --record "$DIR/remote-requests.jsonl" > "$DIR/fake-remote.out" 2>&1 &
  echo $! >> "$DIR/fake-herdr.pids"
  cat > "$DIR/fake-herdr-cli.json" <<JSON
{"local_socket": "$DIR/herdr.sock", "log": "$DIR/herdr-cli.jsonl",
 "machines": [{"id": "fake-main", "label": "Fake Main Mac", "enabled": true, "socket": "$DIR/remote.sock"},
              {"id": "fake-dead", "label": "Fake Dead Mac", "enabled": true, "unreachable": true},
              {"id": "fake-off", "label": "Disabled Mac", "enabled": false, "socket": "$DIR/remote.sock"}]}
JSON
  printf '#!/bin/sh\nexec /usr/bin/python3 "%s/fake-herdr-cli" --fake-config "%s/fake-herdr-cli.json" "$@"\n' "$e2e" "$DIR" > "$DIR/herdr-cli"
  chmod +x "$DIR/herdr-cli"
  local end=$(( $(date +%s) + 10 ))
  while [ ! -S "$DIR/herdr.sock" ] || [ ! -S "$DIR/remote.sock" ]; do
    [ "$(date +%s)" -ge "$end" ] && { echo "fake herdr did not start" >&2; return 1; }
    sleep 0.1
  done
}

stop_fake_herdr() {
  [ -f "$DIR/fake-herdr.pids" ] || return 0
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$DIR/fake-herdr.pids"
  rm -f "$DIR/fake-herdr.pids"
}

case "${1:-serve}" in
  env)
    helper_env
    env | grep '^WHISPERA_LINK_' | grep -v '^WHISPERA_LINK_ACCOUNT_BEARER=' | sort
    [ -n "${WLH_BEARER:-}" ] && echo "WHISPERA_LINK_ACCOUNT_BEARER=<set>"
    echo "config: $DIR/config.json (listen_host $LISTEN, port $PORT)"
    ;;
  serve)
    mkdir -p "$DIR/state"
    printf '{"listen_host": "%s", "port": %s, "herdr_socket": "%s"}\n' "$LISTEN" "$PORT" "$(HERDR_SOCKET)" > "$DIR/config.json"
    (cd "$HERE" && swift build --product link-helper-serve >&2)
    BIN="$(cd "$HERE" && swift build --product link-helper-serve --show-bin-path)/link-helper-serve"
    helper_env
    echo "account-pairing e2e helper: state $DIR/state, log $DIR/helper.log, http://$LISTEN:$PORT, backend $BACKEND" >&2
    if [ "${WLH_FAKE_HERDR:-0}" != 1 ]; then exec "$BIN"; fi
    start_fake_herdr
    echo "fake herdr: $DIR/herdr.sock (this Mac), $DIR/remote.sock (fake-main), fake-dead unreachable" >&2
    trap stop_fake_herdr EXIT
    "$BIN" &
    HELPER_PID=$!
    trap 'kill "$HELPER_PID" 2>/dev/null || true' INT TERM
    set +e
    wait "$HELPER_PID"
    RC=$?
    stop_fake_herdr
    exit "$RC"
    ;;
  herdr|herdr-remote)
    SOCK="$DIR/herdr.sock"; [ "$1" = herdr-remote ] && SOCK="$DIR/remote.sock"
    /usr/bin/python3 "$HERE/e2e/fake_herdr.py" --socket "$SOCK" ctl "${2:?usage: account-pairing.sh $1 '<json>'}"
    ;;
  herdr-requests)
    for f in herdr-requests remote-requests herdr-cli; do
      echo "== $f"; cat "$DIR/$f.jsonl" 2>/dev/null || true
    done
    ;;
  pair-code)
    "$0" admin '{"op":"pair.begin","ttl_s":'"${WLH_PAIR_TTL_S:-300}"'}' | /usr/bin/python3 -c '
import json, sys
r = json.load(sys.stdin)
print("code:        %s" % r["code"])
print("fingerprint: %s   (the phone shows this before it reveals the code)" % r.get("daemon_fp_display", r["daemon_fp"][:16]))
print("url:         %s" % r["url"])
print("qr_payload:  %s" % r["qr_payload"])'
    ;;
  phone)
    shift
    (cd "$HERE" && swift build --product link-soft-phone >&2)
    PHONE_BIN="$(cd "$HERE" && swift build --product link-soft-phone --show-bin-path)/link-soft-phone"
    SUB="${1:?usage: account-pairing.sh phone pair|call …}"; shift
    if [ "$SUB" = pair ] && [[ " $* " != *" --qr "* ]] && [[ " $* " != *" --url "* ]]; then
      CODE="${WLH_PAIR_CODE:-}"
      [ -n "$CODE" ] || { read -r -p "pairing code shown by pair-code: " CODE; }
      exec "$PHONE_BIN" pair --state "$DIR/phone" --url "http://$LISTEN:$PORT" --code "$CODE" "$@"
    fi
    exec "$PHONE_BIN" "$SUB" --state "$DIR/phone" "$@"
    ;;
  admin)
    REQUEST="${2:?usage: account-pairing.sh admin '<json>'}"
    /usr/bin/python3 - "$DIR/state/admin.sock" "$REQUEST" <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(90)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
data = b""
while not data.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
print(data.decode().strip())
PYEOF
    ;;
  *)
    echo "usage: account-pairing.sh [serve|admin '<json>'|env|pair-code|phone pair|call …|herdr '<json>'|herdr-remote '<json>'|herdr-requests]" >&2
    exit 2
    ;;
esac
