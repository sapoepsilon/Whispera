#!/bin/bash
# Screen-records a QA run as a start/stop pair so the driver can act in
# between. stop remuxes with faststart so the file is streamable/attachable.
# Requires the invoking terminal to have the Screen Recording TCC grant.
set -euo pipefail

OUT_DIR="${WHISPERA_QA_DIR:-$HOME/qa-artifacts/whispera}"
PID_FILE="/tmp/whispera-qa-record.pid"
RAW="$OUT_DIR/raw.mov"

case "${1:-}" in
  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "already recording (pid $(cat "$PID_FILE"))" >&2
      exit 1
    fi
    mkdir -p "$OUT_DIR"
    rm -f "$RAW"
    screencapture -v "$RAW" &
    echo $! > "$PID_FILE"
    echo "recording pid $(cat "$PID_FILE") -> $RAW"
    ;;
  stop)
    SLUG="${2:-demo}"
    [ -f "$PID_FILE" ] || { echo "no recording in progress" >&2; exit 1; }
    PID="$(cat "$PID_FILE")"
    # screencapture sometimes ignores a single SIGINT, which leaves a
    # moov-less unplayable file — re-signal until the process exits.
    for _ in 1 2 3 4 5; do
      kill -0 "$PID" 2>/dev/null || break
      kill -INT "$PID" 2>/dev/null || true
      sleep 1
    done
    rm -f "$PID_FILE"
    if kill -0 "$PID" 2>/dev/null; then
      echo "recorder did not exit; recording not finalized" >&2
      exit 1
    fi
    if [ ! -s "$RAW" ]; then
      echo "no recording produced — is Screen Recording granted to this terminal?" >&2
      exit 1
    fi
    OUT="$OUT_DIR/$SLUG.mp4"
    ffmpeg -y -loglevel error -i "$RAW" \
      -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' -pix_fmt yuv420p \
      -movflags +faststart "$OUT"
    rm -f "$RAW"
    SECS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" | cut -d. -f1)"
    echo "saved ${SECS}s -> $OUT"
    ;;
  *)
    echo "usage: $(basename "$0") start | stop [slug]" >&2
    exit 1
    ;;
esac
