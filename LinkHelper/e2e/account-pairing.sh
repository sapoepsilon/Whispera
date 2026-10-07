#!/bin/bash
# A standalone helper for the account-pairing e2e (step 11): no app, no XPC, no Bonjour, its own
# temp config and state, a non-default port — the installed helper and its state are never touched.
#
#   LinkHelper/e2e/account-pairing.sh serve            # build link-helper-serve and run it (foreground)
#   LinkHelper/e2e/account-pairing.sh admin '<json>'   # one admin-socket request, prints the JSON reply
#   LinkHelper/e2e/account-pairing.sh env              # print the environment `serve` uses
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
#   WLH_TEST_CONFIRM  1 = allow admin '{"op":"approve.confirm","device_id":"dev_…"}' (test only;
#                     the app confirms with Touch ID over XPC instead)   default 1
#
# Admin ops (one JSON object per call):
#   {"op":"account.set","bearer":"…","backend_url":"…"}  join the account (registers the Mac once)
#   {"op":"account.status"}                               device_id, phones, last sync, pending confirmations
#   {"op":"account.sync"}                                 sync now: pinned / offered / dropped device ids
#   {"op":"account.clear"}                                leave the account (sends `unpaired` to the phones)
#   {"op":"approve.pending"}                              iPhones waiting for approve confirmation
#   {"op":"approve.confirm","device_id":"dev_…"}          test only, needs WLH_TEST_CONFIRM=1
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
    printf '{"listen_host": "%s", "port": %s, "herdr_socket": "%s/no-herdr.sock"}\n' "$LISTEN" "$PORT" "$DIR" > "$DIR/config.json"
    (cd "$HERE" && swift build --product link-helper-serve >&2)
    BIN="$(cd "$HERE" && swift build --product link-helper-serve --show-bin-path)/link-helper-serve"
    helper_env
    echo "account-pairing e2e helper: state $DIR/state, log $DIR/helper.log, http://$LISTEN:$PORT, backend $BACKEND" >&2
    exec "$BIN"
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
    echo "usage: account-pairing.sh [serve|admin '<json>'|env]" >&2
    exit 2
    ;;
esac
