#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Set Whisper Model
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera
# @raycast.argument1 { "type": "text", "placeholder": "openai_whisper-small.en" }

# Documentation:
# @raycast.description Switch Whispera to an already downloaded model (see List Models).
# @raycast.author Whispera

if [ "$(defaults read "com.macwhisper.app" remoteControlURLSchemeEnabled 2>/dev/null)" != "1" ]; then
  echo "In Whispera Settings, press Shift-Command-D to show Automation, turn on \"Allow whispera:// links\", then try again."
  exit 1
fi
token="$(cat "$HOME/Library/Application Support/Whispera/remote-control-token" 2>/dev/null)"
open -g "whispera://model?name=$1&token=$token"
