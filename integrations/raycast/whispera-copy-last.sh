#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Copy Last Transcript
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Copy the most recent Whispera transcript to the clipboard.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
"$WHISPERA" --copy-last 2>&1
