#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Transcribe Audio File
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.packageName Whispera
# @raycast.argument1 { "type": "text", "placeholder": "Path to audio file" }

# Documentation:
# @raycast.description Transcribe an audio file headlessly and copy the text to the clipboard.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
file="${1/#\~/$HOME}"
text="$("$WHISPERA" --transcribe-file "$file")" || exit 1
printf '%s' "$text" | pbcopy
printf '%s\n' "$text"
