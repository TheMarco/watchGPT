# WatchGPT Handoff

Realtime-ish ChatGPT voice for Apple Watch. This is a two-target SwiftUI project: the watch app captures/plays audio, and the iPhone companion app owns OpenAI networking. They communicate over `WatchConnectivity`.

This is a personal sideloading project. Do not treat it as App Store ready. The iPhone build can embed a live OpenAI API key through local xcconfig plumbing.

Repo: https://github.com/TheMarco/watchGPT.

## Current State

- The watch cannot reliably run the OpenAI WebSocket directly. The iPhone companion is required.
- The watch app supports two voice engines. The user-facing names are **Fast Mode** and **Think Mode** (`VoiceEngine.displayName`); the underlying enum cases are `realtime` and `gpt5` and the persisted UserDefaults values are unchanged.
  - **Fast Mode** (`realtime`): OpenAI `gpt-realtime` over a WebSocket held by the phone.
  - **Think Mode** (`gpt5`): phone-side local speech detection, transcription, Responses API using `gpt-5.5` with iPhone-configurable reasoning effort, then TTS back to the watch.
- **Web search is wired in both modes**:
  - Think Mode passes `tools: [{type: "web_search"}]` and `tool_choice: "auto"` to the Responses API; OpenAI runs the search/fetch/synthesis server-side.
  - Fast Mode registers a `web_search` function tool on `session.update` only when a Brave Search key is configured. The phone bridge listens for `response.output_item.done` with `item.type == "function_call"`, runs the search via `BraveSearchProvider` (8 s timeout), then replies with a `conversation.item.create` of type `function_call_output` followed by `response.create`. No key = no tool registered.
- Hands-free conversation is the default. Push-to-talk remains available through the watch settings.
- **Voice barge-in is OFF by default.** When off, mic forwarding is suppressed for the entire `phase == .speaking` duration AND while `awaitingAssistantResponse` is true (between `speech_stopped` and the next phase transition out of `.speaking`). Tap-to-interrupt always works regardless via `recoverToConnected()` clearing both guards.
- **Mic sensitivity preset** on the watch (`AppConfiguration.micSensitivity`): High/Standard/Low maps to `RealtimeAudioIO.inputGain` values 5.5 / 4.0 / 2.5. Read on prewarm and on session start.
- **Assistant language** picker on the iPhone (`AssistantLanguage`, 38 languages plus Auto). When set, it appends `"Always respond in <Language>…"` to the session prompt and pins the transcription model via `language: "<iso>"` in `input_audio_transcription` (and as the `language` form field on the Think Mode `/v1/audio/transcriptions` upload). Auto strengthens the prompt to fall back to English on any uncertainty.
- **Idle auto-end**: 30 s of `.listening`/`.connected` with no activity triggers `stop()`. The clock resets on every meaningful event (`speechStarted/Stopped`, transcripts, `responseDone`) and — critically — whenever `phase` transitions OUT of `.speaking`, so long monologues don't pre-stale the timer.
- **Audio prewarm**: `RealtimeAudioIO.prepare()` (idempotent) wires the audio graph and configures the session category on `ContentView.onAppear`, so first-tap latency drops; `start()` only does the work that needs HAL active + mic permission.
- **AOD-neutral main button**: when `@Environment(\.isLuminanceReduced)` is true, the button switches to a grayscale gradient and a neutral `waveform` glyph; the audio-reactive halo behind it is muted. Lifting the wrist clears it via the existing `scenePhase`-driven resync.
- **Audio-reactive halo**: `RealtimeVoiceSession.lastInputPeak` is published per mic chunk and feeds the radial blur behind the main button (scale, opacity, blur radius all respond).
- **Cohesive visual system**: the watch uses a rounded-square phase button, round watch artwork in idle/ready states, iPhone reachability pill, premium transcript container, and matching chat bubbles. The iPhone companion uses transparent brand artwork in the hero/About header, layered gradient cards, visible Help/About shortcuts, and a colorful card-based Help screen.
- Haptics were intentionally removed from the watch voice session — destabilizing.
- The phone companion stores chat transcripts as separate sessions with generated titles, one-sentence summaries, and usage metadata. The detail view is iMessage-style chat bubbles. Native swipe-to-delete with no confirmation; the trash icon inside the detail view confirms before deleting.
- The phone companion has a collapsible diagnostics panel on the main screen. It starts closed and expands to show mode, Fast Mode turn-taking, last OpenAI event, reconnects, mic peak, and watch chunks.
- Help/About are available both from the main companion screen and Settings. `PhoneHelpView` and `PhoneAboutView` are shared top-level views rather than private to Settings.
- Root icon sources:
  - `icon.png` is the phone/general brand artwork source and feeds `PhoneAppIcon` plus the in-app `BrandIcon` image set.
  - `icon-watch.png` is the round watch artwork source and feeds `AppIcon` plus the in-app `WatchBrandIcon` image set.

## Why Two Targets

The watchOS networking stack does not reliably allow third-party apps to open arbitrary outbound TLS WebSockets. This was tested with `URLSessionWebSocketTask`, `URLSession+waitsForConnectivity`, and `NWConnection+NWProtocolWebSocket`. Failures included `-1009`, `cancelled`, and `ENETDOWN [POSIX 50]`, even when HTTPS data tasks worked.

The iPhone companion sidesteps that by holding the OpenAI connection and relaying audio/control messages to the watch over Bluetooth via `WCSession`.

## UX

The watch shows a large rounded-square main voice button.

- From disconnected: tap the main button to start a session.
- In hands-free mode: speak naturally after startup.
- In push-to-talk mode: hold the main button to talk, release to commit.
- Tap-to-interrupt during `.speaking` always works (it routes through `beginTurn` → `recoverToConnected`, clearing the playback echo guard and `awaitingAssistantResponse`).
- The watch top bar shows the title, an iPhone reachability pill, and the Settings button.
- Settings on the watch cover interaction/runtime: hands-free, audio replies, mic sensitivity, voice barge-in, workout keep-alive, and clear chat. Model-facing choices live on the iPhone: default mode, per-mode voice, Fast Mode VAD eagerness, Think Mode reasoning, language, and search keys.

Watch phase machine:

```text
disconnected -> connecting -> connected <-> listening
                              ^             |
                              |             v
                              speaking <----/
```

## Layout

- `WatchGPT/` - watchOS target, Swift 5, deployment target 11.0
  - `WatchGPTApp.swift` - app entry, registers defaults.
  - `Views/ContentView.swift` - rounded-square main button UI (TimelineView-driven, AOD-aware, audio-reactive halo/ripples, `WatchBrandIcon` in idle/ready states), reachability/status top bar, transcript view, stop/settings controls.
  - `Views/RealtimeTranscriptBubble.swift` - watch transcript bubble styling shared by live/final transcript lines.
  - `Views/SettingsView.swift` - hands-free, audio replies, mic sensitivity, voice barge-in, workout keep-alive, clear chat.
  - `Services/RealtimeVoiceSession.swift` - watch-side phase machine and `WCSession` client. Owns the idle watchdog, the playback-echo guard, the `awaitingAssistantResponse` flag, and `lastInputPeak` for the halo.
  - `Services/RealtimeAudioIO.swift` - watch mic capture and playback. 24 kHz PCM16 mono. Uses `.voiceChat`, enables voice processing, exposes `prepare()` for cold-start prewarm and a settable `inputGain` for the sensitivity preset.
  - `Support/AppConfiguration.swift` - watch settings keys/defaults plus the `MicSensitivity` enum. No API key on watch.
  - `Info.plist` - mic usage, HealthKit usage, `WKBackgroundModes` for audio and workout processing.
  - `WatchGPT.entitlements` - HealthKit entitlement.
  - `Assets.xcassets/AppIcon.appiconset` - watch icon renditions generated from root `icon-watch.png`.
  - `Assets.xcassets/WatchBrandIcon.imageset` - in-app watch artwork copied from root `icon-watch.png`.
- `WatchGPTPhone/` - iOS companion target, Swift 5, deployment target 17.0
  - `WatchGPTPhoneApp.swift` - app entry, activates `PhoneRealtimeBridge`.
  - `Views/PhoneContentView.swift` - app-icon hero status card with TimelineView pulse, Help/About shortcuts, collapsible diagnostics panel, transcript list (insetGrouped, leading badges), iMessage-style chat-bubble detail view with usage metadata, and shared `PhoneAppIconImage`.
  - `Views/PhoneSettingsView.swift` - OpenAI API key, default mode, per-mode voice, Fast Mode turn-taking, Think Mode reasoning, language picker, Brave Search key, colorful `PhoneHelpView`, and `PhoneAboutView`.
  - `Services/PhoneRealtimeBridge.swift` - phone-side bridge for both engines, transcript persistence, OpenAI calls, keep-alive, web-search tool execution. Inlines `WebSearchProvider`/`BraveSearchProvider` at the top of the file.
  - `Support/PhoneConfiguration.swift` - model names, API keys (OpenAI + Brave), voice config, endpoint builders, language enum, effective-instructions composition.
  - `Config/WatchGPTPhone.xcconfig` - committed; includes gitignored `LocalSecrets.xcconfig`.
- `Shared/RealtimeMessages.swift` - compact message envelope shared by both targets, plus the `VoiceEngine` enum (raw values `realtime`/`gpt5`, displayNames Fast Mode/Think Mode).
- `WatchGPT/Assets.xcassets/PhoneAppIcon.appiconset` - phone icon renditions generated from root `icon.png`.
- `WatchGPT/Assets.xcassets/BrandIcon.imageset` - in-app phone/general brand artwork copied from root `icon.png`.
- `project.yml` - XcodeGen spec. Regenerate after structural target/file changes.

## Engine Details

### Fast Mode (Realtime)

```text
Watch mic PCM16 -> WCSession data -> iPhone -> OpenAI Realtime WebSocket
OpenAI PCM16 deltas -> iPhone -> WCSession data -> Watch playback
```

- Model: `gpt-realtime`.
- Endpoint: `wss://api.openai.com/v1/realtime?model=gpt-realtime`.
- Input/output audio: PCM16, 24 kHz mono.
- Default voice: `marin`.
- Realtime VAD:
  - hands-free uses semantic VAD with `create_response: true` and `interrupt_response: true`
  - push-to-talk sets `turn_detection: null` and sends `input_audio_buffer.commit` + `response.create` manually
- Web search: when `PhoneConfiguration.realtimeWebSearchEnabled` is true (Brave key present), `sendSessionUpdate` registers a `web_search` function tool with `tool_choice: "auto"` and appends a behavior addendum to the instructions. The bridge handles `response.output_item.done` for `function_call` items, runs `BraveSearchProvider.search` (8 s timeout), and sends `function_call_output` + `response.create`.
- `lastSentVoice` / `lastSentLanguage` / `lastSentWebSearchEnabled` track config changes; the UserDefaults observer fires a fresh `session.update` mid-session when any change.
- Audio deltas are buffered to roughly 9,600 bytes before sending back to the watch for lower latency.

### Think Mode (GPT-5.5)

This is not realtime. It is a sequential pipeline on the phone:

```text
Watch mic PCM16 -> WCSession data -> phone local VAD
-> audio transcription -> Responses API (with web_search tool) -> TTS PCM
-> chunked WCSession data -> Watch playback
```

- Text model: `gpt-5.5`.
- Reasoning: `{ "effort": "low" }`.
- Transcription model: `gpt-4o-mini-transcribe`. When a specific language is set, `language: "<iso>"` is added to the multipart upload.
- TTS model: `gpt-4o-mini-tts`.
- TTS voice uses the separate Think Mode voice picker and falls back to `coral`.
- Web search: the Responses API call passes `tools: [{type: "web_search"}]` and `tool_choice: "auto"`. OpenAI runs the search, fetch, and synthesis server-side; we still parse `output_text` (or fall back to walking `output[].content[].text`).
- Think Mode is intentionally one turn at a time:
  - listen → transcribe → think → synthesize → speak → return to listening
- Stability hardening: speech-start debounce, short-burst dropping, chunked TTS forwarding via `sendAudioToWatchInChunks` with paced 8 ms gaps.

## Transcript History

The phone companion persists transcript sessions in `UserDefaults`.

- Data models live in `PhoneRealtimeBridge.swift`:
  - `PhoneTranscriptSession`
  - `PhoneTranscriptLine`
- Storage key: `WatchGPTPhone.transcriptSessions.v2`.
- Legacy migration reads `WatchGPTPhone.transcriptLines.v1` if present.
- Each started voice session creates a new transcript session titled `<Engine.displayName> chat` (so `Fast Mode chat` or `Think Mode chat`). The single source of truth is `engine.displayName + " chat"`.
- On the first user utterance, the title is replaced with a short local fallback title derived from the utterance. When the session ends, the phone asks OpenAI for compact transcript metadata and stores a better title plus one-sentence summary.
- Session usage metadata is saved with each transcript: duration, approximate mic audio, OpenAI event count, web searches, reconnects, and engine.
- `PhoneContentView` shows session history (insetGrouped list with leading badges), an iMessage-style chat-bubble detail view (asymmetric corner bubbles, accent fill for user, material for assistant), copy/share via context menu, native swipe-to-delete with no extra confirmation, and a `Clear all` button in the section header that does confirm.
- `PhoneAppIconImage` reads the bundled primary app icon via `CFBundleIcons` and falls back to a generated gradient symbol if needed. It is intentionally shared by the main hero and About screen.

## Runtime / Sleep Notes

`WatchRuntimeKeeper` in `RealtimeVoiceSession.swift` starts:

- `WKExtendedRuntimeSession`
- optional `HKWorkoutSession` with `.mindAndBody`

This is the best currently implemented path for keeping watch execution alive. It is not a magic screen-lock override:

- wrist-down can still dim the display
- off-wrist/unlocked behavior is bad and can trigger PIN prompts
- entitlement or background mode changes may require deleting/reinstalling the watch app
- the watch app should be tested while worn and unlocked

## Important Invariants

- API keys (OpenAI + optional Brave) live only on the iPhone.
- Watch and iPhone apps both need to be running/reachable for live sessions.
- `WCSession.sendMessageData` is used for raw audio bytes.
- `WCSession.sendMessage` is used for compact control/text messages.
- `RealtimeMessageKey.type` is `"t"` and text is `"x"`.
- Audio format is 24 kHz PCM16 mono in both directions.
- Avoid adding haptics back into the watch voice session unless there is a very specific reason and on-device evidence that it does not destabilize the session.
- The assistant prompt explicitly says it has no visual/camera/screen/location/sensor access. This was added after it said things like "I can see you."
- The system prompt is composed in `PhoneConfiguration.effectiveInstructions`, which appends a language directive when a specific language is picked. Fast Mode further appends a `web_search` behavior addendum when a Brave key is present (handled in `sendSessionUpdate`). Think Mode appends its own web_search addendum inside `createRegularResponse`. Don't fork these accidentally — keep `effectiveInstructions` as the base and append per-mode.
- `VoiceEngine` raw values (`realtime`, `gpt5`) are persisted in UserDefaults and must not change. Display names come from `displayName`.
- Tap-to-interrupt must keep working in every barge-in/echo-guard configuration. `recoverToConnected()` is the single place that clears `playbackEndsAt`, `awaitingAssistantResponse`, and the assistant draft.

## Commands

```sh
# Configure the iPhone build with an API key from ./.env or OPENAI_API_KEY.
npm run configure:phone

# Regenerate Xcode project after adding/removing files or changing project.yml.
xcodegen generate

# Typecheck core watch files.
xcrun --sdk watchos swiftc -typecheck \
  Shared/RealtimeMessages.swift \
  WatchGPT/Models/RealtimeTranscriptLine.swift \
  WatchGPT/Support/AppConfiguration.swift \
  WatchGPT/Services/RealtimeAudioIO.swift \
  WatchGPT/Services/RealtimeVoiceSession.swift \
  -target arm64-apple-watchos11.0 \
  -module-cache-path /tmp/WatchGPTSwiftModuleCache

# Typecheck watch UI without Preview macros.
mkdir -p /tmp/watchgpt-typecheck-watch
awk '/#Preview/ {exit} {print}' WatchGPT/Views/ContentView.swift > /tmp/watchgpt-typecheck-watch/ContentView.swift
awk '/#Preview/ {exit} {print}' WatchGPT/Views/SettingsView.swift > /tmp/watchgpt-typecheck-watch/SettingsView.swift
xcrun --sdk watchos swiftc -typecheck \
  Shared/RealtimeMessages.swift \
  WatchGPT/Models/RealtimeTranscriptLine.swift \
  WatchGPT/Support/AppConfiguration.swift \
  WatchGPT/Services/RealtimeAudioIO.swift \
  WatchGPT/Services/RealtimeVoiceSession.swift \
  WatchGPT/Views/RealtimeTranscriptBubble.swift \
  /tmp/watchgpt-typecheck-watch/ContentView.swift \
  /tmp/watchgpt-typecheck-watch/SettingsView.swift \
  WatchGPT/WatchGPTApp.swift \
  -target arm64-apple-watchos11.0 \
  -module-cache-path /tmp/WatchGPTSwiftModuleCache

# Typecheck core phone bridge.
xcrun --sdk iphoneos swiftc -typecheck \
  Shared/RealtimeMessages.swift \
  WatchGPTPhone/Support/PhoneConfiguration.swift \
  WatchGPTPhone/Services/PhoneRealtimeBridge.swift \
  -target arm64-apple-ios17.0 \
  -module-cache-path /tmp/WatchGPTSwiftModuleCache

# Typecheck phone UI without Preview macros.
mkdir -p /tmp/watchgpt-typecheck-phone
awk '/#Preview/ {exit} {print}' WatchGPTPhone/Views/PhoneContentView.swift > /tmp/watchgpt-typecheck-phone/PhoneContentView.swift
awk '/#Preview/ {exit} {print}' WatchGPTPhone/Views/PhoneSettingsView.swift > /tmp/watchgpt-typecheck-phone/PhoneSettingsView.swift
xcrun --sdk iphoneos swiftc -typecheck \
  Shared/RealtimeMessages.swift \
  WatchGPTPhone/Support/PhoneConfiguration.swift \
  WatchGPTPhone/Services/PhoneRealtimeBridge.swift \
  /tmp/watchgpt-typecheck-phone/PhoneContentView.swift \
  /tmp/watchgpt-typecheck-phone/PhoneSettingsView.swift \
  WatchGPTPhone/WatchGPTPhoneApp.swift \
  -target arm64-apple-ios17.0 \
  -module-cache-path /tmp/WatchGPTSwiftModuleCache

# Quick asset catalog checks.
xcrun actool WatchGPT/Assets.xcassets \
  --compile /tmp/WatchGPTAssetCheck-iOS \
  --output-format human-readable-text \
  --warnings --notices \
  --app-icon PhoneAppIcon \
  --accent-color AccentColor \
  --platform iphoneos \
  --target-device iphone \
  --minimum-deployment-target 17.0

xcrun actool WatchGPT/Assets.xcassets \
  --compile /tmp/WatchGPTAssetCheck-watch \
  --output-format human-readable-text \
  --warnings --notices \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --platform watchos \
  --target-device watch \
  --minimum-deployment-target 11.0
```

Note: full `xcodebuild` may fail in this local environment because CoreSimulator/watch simulator runtimes are broken or unavailable. The Swift typechecks above have been the more reliable sanity checks.

## Gotchas

- `LocalSecrets.xcconfig`, `.env`, and `.claude/` are gitignored. Never commit secrets.
- `project.yml` and `WatchGPT.xcodeproj/project.pbxproj` are both currently updated. If you regenerate with XcodeGen, re-check target resource phases and app icon names:
  - Watch target: `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
  - Phone target: `ASSETCATALOG_COMPILER_APPICON_NAME = PhoneAppIcon`
- The phone target needs the shared `WatchGPT/Assets.xcassets` resource for `PhoneAppIcon`.
- `sendMessageData` can be fragile with large payloads. GPT-5.5 TTS audio is chunked via `sendAudioToWatchInChunks`.
- `WCSession.isReachable` flickers. Watch logs reachability changes but should not tear down sessions just because it flips.
- `RealtimeVoiceSession` and `PhoneRealtimeBridge` handle old and new OpenAI realtime event names. Keep both forms unless tested.
- If the watch app will not launch after entitlement/background-mode changes, delete/reinstall the watch app and rebuild from the phone target.

## Known Weak Points / Next Debugging Targets

- Think Mode has been twitchy on-device. The current mitigation is local VAD debounce plus short-burst dropping, but it still needs real watch testing.
- Think Mode "never speaks back" was likely caused by sending synthesized speech as one huge `sendMessageData` payload. It is now chunked/paced, but verify on device.
- Fast Mode is still the smoother path. Think Mode is turn-based and will never feel as immediate as `gpt-realtime`, especially with web search adding another round-trip.
- The watch screen can still dim. Workout runtime helps process lifetime; the AOD-aware main button makes the dim state look intentional rather than broken.
- If OpenAI rejects `gpt-5.5`, the user may not have API access to that model. The phone bridge should surface the API error.
- Background pickup is limited. If the iPhone app is force-quit, the watch cannot revive it.
- Reconnect during an in-flight turn can lose buffered audio. The UX should eventually surface "connection dropped, try again" more explicitly.
- Web search latency adds 1-3 s before the spoken reply starts in either mode. The realtime instructions tell the model to say a brief preamble ("Let me check.") before slow searches; verify it actually does that on-device.
- The Brave free tier has aggressive rate limits. Heavy use can return 429s — the phone surfaces these as `Search HTTP 429: …` in `function_call_output` so the model can recover, but watch out for it during testing.
