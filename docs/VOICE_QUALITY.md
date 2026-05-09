# Voice quality bar

Should feel close to ChatGPT Voice on a phone.

## Must have

- Start a session with one tap on the watch.
- iPhone companion can be in the foreground (no setup beyond running the app).
- Natural turn-taking via OpenAI's semantic VAD (configured by the iPhone bridge, not the watch).
- Assistant audio starts streaming on the watch before the full answer is complete.
- User can interrupt while the assistant is speaking.
- Transcript updates do not block audio playback.
- Clear connection state on the watch.
- Physical Apple Watch Ultra testing, not only simulator testing.

## Latency budget

- Mic chunk → watch → iPhone → OpenAI: should be a few hundred milliseconds end-to-end. Bluetooth `WCSession.sendMessageData` is the highest-variance hop; if you see audible delay, it's almost always there.
- First assistant delta back to the watch should begin within a couple of seconds of the user finishing their turn.
- Barge-in should stop queued playback immediately when user speech starts (`audioIO.stopPlayback()` on `speechStarted`).

## Tuning knobs

Constants live in `WatchGPTPhone/Support/PhoneConfiguration.swift` and are sent via `session.update` from `PhoneRealtimeBridge.sendSessionUpdate()`:

- `realtimeModel` (default `gpt-realtime` — the GA model; flip to `gpt-realtime-2` if your account has access and add `reasoning.effort` back to the session payload)
- `realtimeVoice` (default `marin`)
- `realtimeEagerness` (default `low` / Patient — semantic VAD, configurable in iPhone Settings)
- `realtimeInstructions` (system prompt)

## Known risks

- Physical watch microphone and speaker behavior differs from simulator.
- iPhone going to background can cut the WC channel; sessions die until iPhone is reopened.
- The build embeds your OpenAI API key on the iPhone. Do not distribute.
