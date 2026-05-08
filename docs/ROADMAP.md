# Roadmap

## Near term

- Background runtime for the iPhone (`BGTaskScheduler` / `WKExtendedRuntimeSession` if applicable) so brief iPhone backgrounding doesn't kill watch sessions.
- Surface iPhone reachability on the watch UI before the user taps the orb (so failure mode is "iPhone needs to be open" instead of a generic error).
- Tune end-to-end latency on a physical Apple Watch Ultra.
- Audio level visualization and connection-health telemetry.
- Configurable voice and VAD eagerness in iPhone Settings.

## Later

- Shortcuts action for quick prompts.
- Complication for starting voice capture.
- Conversation persistence on the iPhone (transcript history).
- Re-evaluate standalone watch path after major watchOS releases — current limitation is an OS-level restriction on third-party WSS that may relax over time.
