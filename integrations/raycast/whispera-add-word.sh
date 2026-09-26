#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Add Word to Dictionary
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera
# @raycast.argument1 { "type": "text", "placeholder": "Word or phrase" }

# Documentation:
# @raycast.description Add a name or term to Whispera's custom words; separate several with commas.
# @raycast.author Whispera

WHISPERA="${WHISPERA_CLI:-/Applications/Whispera.app/Contents/MacOS/Whispera}"
"$WHISPERA" --add-word "$1"
