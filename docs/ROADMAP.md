# Roadmap

## Near term

- Background runtime for the iPhone (`BGTaskScheduler` / `WKExtendedRuntimeSession` if applicable) so brief iPhone backgrounding doesn't kill watch sessions.
- Tune end-to-end latency and bounded-queue thresholds on a physical Apple Watch Ultra.
- Physical-device validation for session sequencing, long spoken turns, reconnect notices, diagnostics, and usage metadata.
- Cost estimation beyond rough usage counters if model-side token/audio accounting becomes easy to retrieve.
- Continue decomposing the phone bridge into smaller transport, pipeline, persistence, and presentation components as behavior stabilizes.

## Later

- Shortcuts action for quick prompts.
- Complication for starting voice capture.
- Re-evaluate standalone watch path after major watchOS releases — current limitation is an OS-level restriction on third-party WSS that may relax over time.
- Evaluate pinned OpenAI model snapshots if alias behavior becomes too variable for repeatable personal builds.
