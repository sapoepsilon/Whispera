# IMPORTANT: NEVER USE SIMULATED TRANSCRIPTION

## CRITICAL RULE: ALWAYS USE REAL TRANSCRIPTION
- The user explicitly requires REAL WhisperKit transcription everywhere
- NEVER implement fake/simulated/test transcription responses
- The onboarding test MUST use actual WhisperKit.transcribe()
- If there are MPS crashes, fix the underlying issue, don't simulate

## Development Process:
	-	Get the required plans; if you are not sure, ask the user.
	-	Implement the plan as specified by the user through the plan mode.
	-	Once implemented, try to build the Xcode project. If the project builds 
successfully, proceed to the next step.
	-	Run tests to make sure you didn’t break anything along the way.
	-	If something breaks, determine whether the issue is with the implementation or the tests. Ask for the user’s permission if you need to refactor the tests.
	-	Ask the user if the implementation is correct.
	-	Create new tests for the new implementation.
	-       I have a logger, please use that one instead of print, or OS.logger
