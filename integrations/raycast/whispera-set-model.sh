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

open -g "whispera://model?name=$1"
