# IMPORTANT: NEVER USE SIMULATED TRANSCRIPTION

## CRITICAL RULE: ALWAYS USE REAL TRANSCRIPTION
- The user explicitly requires REAL WhisperKit transcription everywhere
- NEVER implement fake/simulated/test transcription responses
- The onboarding test MUST use actual WhisperKit.transcribe() 
- If there are MPS crashes, fix the underlying issue, don't simulate

## MPS (Metal Performance Shaders) Issues
- MPS crashes happen due to initialization timing or resource conflicts
- Fix by ensuring proper WhisperKit initialization sequence
- Fix by adding proper error handling and retries
- Fix by ensuring Metal context is ready before transcription
- DO NOT work around with fake transcription

## Current Status
- Need to remove the transcribeForOnboarding() simulated method
- Need to fix the real MPS crash in onboarding
- All transcription must go through WhisperKit.transcribe()