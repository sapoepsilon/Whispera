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

token="$(cat "$HOME/Library/Application Support/Whispera/remote-control-token" 2>/dev/null)"
open -g "whispera://history?token=$token"
