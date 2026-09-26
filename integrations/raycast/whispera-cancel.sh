#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Cancel Dictation
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Stop Whispera dictation and discard the recording.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
"$WHISPERA" --cancel 2>&1
