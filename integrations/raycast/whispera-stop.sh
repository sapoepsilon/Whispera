#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Stop Dictation
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Stop Whispera dictation and paste the transcript.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
"$WHISPERA" --stop 2>&1
