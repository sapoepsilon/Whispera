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

language="$1"
open -g "whispera://language?name=${language// /%20}"
