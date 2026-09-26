#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Set Dictation Language
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera
# @raycast.argument1 { "type": "text", "placeholder": "German or de" }

# Documentation:
# @raycast.description Switch Whispera's transcription language by name or code.
# @raycast.author Whispera

if [ "$(defaults read "com.macwhisper.app" remoteControlURLSchemeEnabled 2>/dev/null)" != "1" ]; then
  echo "Turn on \"Allow whispera:// links\" in Whispera Settings > Automation, then try again."
  exit 1
fi
token="$(cat "$HOME/Library/Application Support/Whispera/remote-control-token" 2>/dev/null)"
language="$1"
open -g "whispera://language?name=${language// /%20}&token=$token"
