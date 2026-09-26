#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title List Whisper Models
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Show the models Whispera has downloaded; * marks the default.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
"$WHISPERA" --list-models
