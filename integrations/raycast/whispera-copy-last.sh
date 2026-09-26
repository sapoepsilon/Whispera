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

token="$(cat "$HOME/Library/Application Support/Whispera/remote-control-token" 2>/dev/null)"
open -g "whispera://copy-last?token=$token"
