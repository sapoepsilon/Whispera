#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Open Transcription History
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Open Whispera's history window.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
"$WHISPERA" --open-history 2>&1
