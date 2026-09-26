#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Toggle Dictation
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Start or stop Whispera dictation.
# @raycast.author Whispera

token="$(cat "$HOME/Library/Application Support/Whispera/remote-control-token" 2>/dev/null)"
open -g "whispera://toggle?token=$token"
