import Foundation

/// The wire format, encoded and decoded in one place.
///
/// The proxy in front of the engine is a verbatim relay — it does not parse frames
/// — so the contract is between this file and the engine, and nothing in between
/// will correct a mistake made here.
enum RealtimeProtocol {
	// MARK: - Outbound

	/// The frame that selects the transcription model, and stops the engine
	/// answering back.
	///
	/// Selecting the model is not optional, despite reading like configuration.
	/// speaches advertises `…whisper-small.en` in `session.created`, which is
	/// frequently not the model actually installed; without this frame the session
	/// connects, accepts audio, and returns nothing, with no error to explain it.
	///
	/// `create_response: false` is the load-bearing half. The Realtime API is a
	/// *conversational* protocol: once server-side VAD closes an utterance the
	/// engine generates an assistant reply for it. speaches routes that reply at a
	/// chat-completions backend, and on a host where none is configured the
	/// resulting `openai.APIConnectionError` escapes as an unhandled exception
	/// group and tears the whole socket down — about 1.5 s after the first
	/// transcript, which is exactly long enough to look like a transcription that
	/// worked. Sending it explicitly here, rather than trusting a default, is
	/// still correct even now that `DictationConfiguration` puts `intent=transcription`
	/// on the connection URL: against the pre-upgrade engine build, asking for
	/// transcription-only via `intent` alone did not help — sessions with and
	/// without it were byte-identical, `create_response` included. Against
	/// speaches 0.9.0-rc.3, `intent=transcription` *does* change the session —
	/// `session.created.turn_detection.create_response` now reads `false` by
	/// default in that mode, where it reads `true` in conversational mode — but
	/// sending the field here anyway costs nothing (measured: no complaint of its
	/// own in transcription mode) and does not depend on trusting that a future
	/// engine build keeps the default this way.
	///
	/// - Parameters:
	///   - silenceDurationMs: how long the engine should wait for trailing silence
	///     before closing an utterance. Pass the engine's own advertised value to
	///     leave its behaviour unchanged, or a smaller one to close utterances
	///     sooner — see `DictationConfiguration.vadSilenceDurationMs`. Measured
	///     against speaches with a 5.16 s fixture, paced at 24 kHz: the engine's
	///     own default of 550 ms cost ~0.96 s from the last spoken sample to
	///     `transcription.completed`; 300 ms cost ~0.66 s. The gap tracks the
	///     requested value almost exactly, so it is safe to lower — down to a
	///     point: too low starts splitting a speaker's natural mid-sentence
	///     pauses into separate utterances, which was not measured here and is
	///     a product tradeoff, not a protocol one.
	///   - threshold, prefixPaddingMs: the engine's own VAD tuning from
	///     `session.created`, echoed back verbatim rather than user-configurable.
	///     Sending a `turn_detection` block replaces the engine's wholesale, and
	///     speaches' `TurnDetection` model declares `create_response`,
	///     `silence_duration_ms`, `threshold` and `prefix_padding_ms` as required
	///     fields with no schema default. Omit any one of them — this file used to
	///     omit these two — and speaches fails to parse the block as `TurnDetection`
	///     and silently falls back to leaving turn detection untouched: not just
	///     `silence_duration_ms`, but `create_response: false` along with it. That
	///     silent fallback is the reason the crash described above (an unhandled
	///     `openai.APIConnectionError` tearing the socket down ~1.4s after the
	///     first transcript) kept happening even after `create_response: false` was
	///     added — the field was correct, and never once applied. Confirmed by
	///     reading `session_event_router.py` and `types/realtime.py` in the
	///     speaches source (in a running speaches container), and reproduced twice each
	///     way with a raw probe: omit `threshold`/`prefixPaddingMs` and
	///     `session.updated` echoes the untouched engine defaults
	///     (`create_response: true`, `silence_duration_ms: 550`) and the socket
	///     dies on schedule; include them and `session.updated` echoes exactly what
	///     was requested, and the socket stays healthy.
	///
	///     `prefixPaddingMs` must be echoed, not omitted — but never changed:
	///     speaches structurally requires the field to be present for the block to
	///     parse, while separately rejecting any *attempt* to change it with an
	///     `invalid_request_error` naming that exact field (see
	///     `Inbound`/`decode`, which treats that one message as informational
	///     rather than fatal). Sending the engine's own value back satisfies the
	///     former without triggering the latter's substance — only its one warning
	///     frame, which is expected on every session against this build.
	static func sessionUpdate(
		model: String, language: String?, silenceDurationMs: Int? = nil, threshold: Double? = nil,
		prefixPaddingMs: Int? = nil
	) throws -> String {
		var transcription: [String: Any] = ["model": model]
		if let language { transcription["language"] = language }
		var turnDetection: [String: Any] = ["type": "server_vad", "create_response": false]
		if let silenceDurationMs { turnDetection["silence_duration_ms"] = silenceDurationMs }
		if let threshold { turnDetection["threshold"] = threshold }
		if let prefixPaddingMs { turnDetection["prefix_padding_ms"] = prefixPaddingMs }
		return try encode([
			"type": "session.update",
			"session": [
				"modalities": ["text"],
				"input_audio_transcription": transcription,
				"turn_detection": turnDetection,
			],
		])
	}

	/// A chunk of audio. Base64 of raw PCM16 — no WAV header, no data URI prefix.
	static func audioAppend(pcm: Data) throws -> String {
		try encode([
			"type": "input_audio_buffer.append",
			"audio": pcm.base64EncodedString(),
		])
	}

	/// Optional against a server-VAD engine, which auto-commits. Sent on flush
	/// anyway: it costs one frame and it is the difference between "works" and
	/// "hangs" against any engine whose VAD is off.
	static func audioCommit() throws -> String {
		try encode(["type": "input_audio_buffer.commit"])
	}

	private static func encode(_ object: [String: Any]) throws -> String {
		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		guard let text = String(data: data, encoding: .utf8) else {
			throw DictationError.protocolViolation("could not encode an outbound frame as UTF-8")
		}
		return text
	}

	// MARK: - Inbound

	/// One decoded server frame.
	///
	/// Everything not needed is dropped rather than modelled: the engine emits
	/// rate-limit, conversation-item and response events this package has no use
	/// for, and enumerating them would mean editing this file every time the
	/// engine adds one.
	enum Inbound: Equatable {
		/// `silenceDurationMs` is the engine's own VAD threshold, echoed in
		/// `session.created`. Worth pulling out: it is exactly how much trailing
		/// silence the client must send to close a turn, and guessing it is the
		/// difference between a transcript and none at all.
		///
		/// `threshold` and `prefixPaddingMs` are pulled out for the same reason as
		/// `silenceDurationMs`, but never overridden: they exist so `sessionUpdate`
		/// can echo them back, which — against speaches — is mandatory rather than
		/// polite. See `sessionUpdate` for why.
		case sessionCreated(
			id: String, silenceDurationMs: Int?, threshold: Double?, prefixPaddingMs: Int?)
		case sessionUpdated(model: String?)
		case speechStarted
		case speechStopped
		case committed
		/// A fragment of the utterance in flight — the text new since the previous
		/// frame, carried in the engine's `delta` field.
		case transcriptDelta(String)
		/// The whole utterance in flight, carried in a `…transcription.delta`
		/// frame's `transcript` field instead of `delta`.
		///
		/// Kept apart from `transcriptDelta` because a host has to *replace* its
		/// draft with this rather than append to it, and the two are
		/// indistinguishable once the field name is thrown away — which is exactly
		/// what this decoder used to do by preferring `transcript` over `delta` for
		/// every frame in the namespace. See WHI-67/69.
		case transcriptHypothesis(String)
		/// A committed utterance. `itemId` is the engine's conversation-item id,
		/// when the frame carries one — it is what a dedup layer keys on, since a
		/// server that re-emits an utterance sends the same id both times. See
		/// `DictationSession.handle(_:)`.
		case transcriptCompleted(text: String, itemId: String?)
		case failed(message: String, code: String?)
		case other(type: String)
	}

	static func decode(_ text: String) throws -> Inbound {
		guard let data = text.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			throw DictationError.protocolViolation("server sent a frame that is not a JSON object")
		}

		// Checked before `type`, and on purpose: speaches emits bare
		// `{"error":{"message":"Not Found"}}` with no `type` at all, so a decoder
		// that keys off `type` first classifies a hard failure as an unknown event
		// and hangs waiting for a transcript that is never coming.
		if let error = object["error"] as? [String: Any] {
			let message =
				error["message"] as? String
				?? error["type"] as? String
				?? "the server reported an unspecified error"
			// One specific message is informational rather than fatal: speaches
			// structurally requires `turn_detection.prefix_padding_ms` to be present
			// for the block to parse (see `sessionUpdate`), while separately
			// refusing to let a client change it. Echoing the engine's own value
			// back — the only way to satisfy the former — reliably draws this exact
			// complaint on every session against this build. Treating it as fatal
			// would spend the one reconnect budget on a warning before a single
			// frame of audio is sent, and then leave the session with none left for
			// an actual failure later. Matched on substring rather than an error
			// code because speaches sends none for this message (`code` is null in
			// the frame observed).
			if message.contains("prefix_padding_ms") && message.contains("not supported") {
				return .other(type: "error.ignored.turn_detection.prefix_padding_ms")
			}
			// speaches 0.9.0-rc.3's VAD can re-fire a turn it already closed — observed
			// when trailing silence arrives in a burst rather than paced in real time,
			// which a slow event loop or a scheduling hiccup can produce even from a
			// well-behaved client. The second attempt to create the same conversation
			// item draws this error, but the session is not actually broken: the first
			// item is still there, and its transcript still arrives (sometimes more
			// than once — see `DictationSession`'s dedup of `transcriptCompleted`).
			// Tearing the socket down here would spend the reconnect budget on a
			// symptom instead of the transcript that is already on its way.
			// Reproduced directly: `POST`ing silence unpaced can draw well over a
			// dozen of these in a row for one utterance, followed by several duplicate
			// `.completed` events, all sharing one item id.
			if message.contains("already exists") {
				return .other(type: "error.ignored.duplicate_item")
			}
			// A client that turns on `sendsExplicitCommit` against a server-VAD engine
			// races its own commit against the VAD's: by the time it arrives the
			// buffer the VAD already closed is empty, and speaches answers this rather
			// than `already exists`. Same non-fatal shape, different build's wording —
			// harmless either way because `sendsExplicitCommit` is not the mechanism
			// that closes the turn.
			if message.contains("Error committing input audio buffer") && message.contains("buffer too small") {
				return .other(type: "error.ignored.duplicate_commit")
			}
			return .failed(message: message, code: error["code"] as? String)
		}

		guard let type = object["type"] as? String else {
			throw DictationError.protocolViolation("server frame has neither 'type' nor 'error'")
		}

		switch type {
		case "session.created":
			let session = object["session"] as? [String: Any]
			let turnDetection = session?["turn_detection"] as? [String: Any]
			return .sessionCreated(
				id: session?["id"] as? String ?? "",
				silenceDurationMs: turnDetection?["silence_duration_ms"] as? Int,
				threshold: turnDetection?["threshold"] as? Double,
				prefixPaddingMs: turnDetection?["prefix_padding_ms"] as? Int)
		case "session.updated":
			let session = object["session"] as? [String: Any]
			let transcription = session?["input_audio_transcription"] as? [String: Any]
			return .sessionUpdated(model: transcription?["model"] as? String)
		case "input_audio_buffer.speech_started":
			return .speechStarted
		case "input_audio_buffer.speech_stopped":
			return .speechStopped
		case "input_audio_buffer.committed":
			return .committed
		default:
			// Prefix-matched rather than listed. Input transcription events are
			// namespaced, and the engine has shipped `.delta`, `.completed` and
			// `.failed` under it at different times; matching the namespace means a
			// new sibling is at worst ignored instead of silently swallowing text.
			let namespace = "conversation.item.input_audio_transcription."
			if type.hasPrefix(namespace) {
				let delta = object["delta"] as? String
				let whole = object["transcript"] as? String
				let text = whole ?? delta
				let itemId = object["item_id"] as? String
				if type.hasSuffix(".completed") {
					return .transcriptCompleted(text: text ?? "", itemId: itemId)
				}
				if type.hasSuffix(".delta") {
					// `delta` first, and that order is the fix. A `.delta` frame that
					// carries both fields means "here is the new fragment, and here is
					// the whole utterance it belongs to"; reading `transcript` first —
					// which this did — handed the host the whole utterance while
					// labelling it a fragment, so the host appended a string that
					// already contained its own draft. A frame carrying only
					// `transcript` is a full hypothesis and is reported as one.
					if let delta { return .transcriptDelta(delta) }
					if let whole { return .transcriptHypothesis(whole) }
					return .transcriptDelta("")
				}
				if let text, !text.isEmpty {
					// An unrecognised member of the namespace that still carries text
					// is treated as committed rather than dropped.
					return .transcriptCompleted(text: text, itemId: itemId)
				}
			}
			return .other(type: type)
		}
	}
}
