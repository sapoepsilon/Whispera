#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Stop Dictation
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Whispera

# Documentation:
# @raycast.description Stop Whispera dictation and paste the transcript.
# @raycast.author Whispera

open -g "whispera://stop"
