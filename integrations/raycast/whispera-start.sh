#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Start Dictation
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Start Whispera dictation.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
"$WHISPERA" --start 2>&1
