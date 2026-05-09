# WatchGPT Handoff

Realtime-ish ChatGPT voice for Apple Watch. This is a two-target SwiftUI project: the watch app captures/plays audio, and the iPhone companion app owns OpenAI networking. They communicate over `WatchConnectivity`.

This is a personal sideloading project. Do not treat it as App Store ready. The iPhone build can embed a live OpenAI API key through local xcconfig plumbing.

Repo: https://github.com/TheMarco/watchGPT.

## Current State

- The watch cannot reliably run the OpenAI WebSocket directly. The iPhone companion is required.
- The watch app supports two voice engines:
  - **Realtime**: OpenAI `gpt-realtime` over a WebSocket held by the phone.
  - **GPT-5.5**: phone-side local speech detection, transcription, Responses API using `gpt-5.5` with reasoning effort `low`, then TTS back to the watch.
- Hands-free conversation is the default. Push-to-talk remains available through the watch settings.
- Workout runtime support is enabled for keeping the watch process alive longer, but it does not keep the physical display bright forever. The watch must be worn/unlocked for sane behavior.
- Haptics were removed from the watch voice session because they appeared to make the experience less stable.
- The phone companion now stores chat transcripts as separate sessions with generated titles. Transcripts can be opened, copied, shared, swipe-deleted individually, or cleared all at once.
- `icon.png` at the repo root is the source image for both app icons:
  - watch target uses `AppIcon`
  - phone target uses `PhoneAppIcon`

## Why Two Targets

The watchOS networking stack does not reliably allow third-party apps to open arbitrary outbound TLS WebSockets. This was tested with `URLSessionWebSocketTask`, `URLSession+waitsForConnectivity`, and `NWConnection+NWProtocolWebSocket`. Failures included `-1009`, `cancelled`, and `ENETDOWN [POSIX 50]`, even when HTTPS data tasks worked.

The iPhone companion sidesteps that by holding the OpenAI connection and relaying audio/control messages to the watch over Bluetooth via `WCSession`.

## UX

The watch shows a large orb.

- From disconnected: tap the orb to start a session.
- In hands-free mode: speak naturally after startup.
- In push-to-talk mode: hold the orb to talk, release to commit.
- Settings on the watch choose the engine: Realtime or GPT-5. The label may still say GPT-5 in UI, but the configured model is currently `gpt-5.5`.

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
  - `Views/ContentView.swift` - orb UI, transcript view, stop/settings controls.
  - `Views/SettingsView.swift` - engine picker, hands-free toggle, audio replies, workout runtime toggle.
  - `Services/RealtimeVoiceSession.swift` - watch-side phase machine and `WCSession` client. Starts/stops runtime keeper, sends audio/control messages to phone, receives phone audio/events.
  - `Services/RealtimeAudioIO.swift` - watch mic capture and playback. 24 kHz PCM16 mono. Uses `.voiceChat` and enables voice processing when available.
  - `Support/AppConfiguration.swift` - watch settings keys/defaults. No API key on watch.
  - `Info.plist` - mic usage, HealthKit usage, `WKBackgroundModes` for audio and workout processing.
  - `WatchGPT.entitlements` - HealthKit entitlement.
  - `Assets.xcassets/AppIcon.appiconset` - watch icon renditions generated from root `icon.png`.
- `WatchGPTPhone/` - iOS companion target, Swift 5, deployment target 17.0
  - `WatchGPTPhoneApp.swift` - app entry, activates `PhoneRealtimeBridge`.
  - `Views/PhoneContentView.swift` - status screen plus transcript session list/detail UI.
  - `Views/PhoneSettingsView.swift` - API key and realtime voice picker.
  - `Services/PhoneRealtimeBridge.swift` - phone-side bridge for both engines, transcript persistence, OpenAI calls, keep-alive handling.
  - `Support/PhoneConfiguration.swift` - model names, API key plumbing, voice config, endpoint builders.
  - `Config/WatchGPTPhone.xcconfig` - committed; includes gitignored `LocalSecrets.xcconfig`.
- `Shared/RealtimeMessages.swift` - compact message envelope shared by both targets.
- `WatchGPT/Assets.xcassets/PhoneAppIcon.appiconset` - phone icon renditions generated from root `icon.png`.
- `project.yml` - XcodeGen spec. Regenerate after structural target/file changes.

## Engine Details

### Realtime Engine

```text
Watch mic PCM16 -> WCSession data -> iPhone -> OpenAI Realtime WebSocket
OpenAI PCM16 deltas -> iPhone -> WCSession data -> Watch playback
```

- Model: `gpt-realtime`.
- Endpoint: `wss://api.openai.com/v1/realtime?model=gpt-realtime`.
- Input/output audio: PCM16, 24 kHz mono.
- Default realtime voice: `marin`.
- Realtime VAD:
  - hands-free uses semantic VAD with `create_response: true` and `interrupt_response: true`
  - push-to-talk sets `turn_detection: null` and sends `input_audio_buffer.commit` + `response.create` manually
- Audio deltas are buffered to roughly 9,600 bytes before sending back to the watch for lower latency.

### GPT-5.5 Engine

This is not realtime. It is a sequential pipeline on the phone:

```text
Watch mic PCM16 -> WCSession data -> phone local VAD
-> audio transcription -> Responses API -> TTS PCM
-> chunked WCSession data -> Watch playback
```

- Text model: `gpt-5.5`.
- Reasoning: `{ "effort": "low" }`.
- Transcription model: `gpt-4o-mini-transcribe`.
- TTS model: `gpt-4o-mini-tts`.
- TTS voice reuses the selected realtime voice when valid for TTS; otherwise falls back to `coral`.
- GPT mode is intentionally one turn at a time:
  - listen
  - transcribe
  - think
  - synthesize
  - speak
  - return to listening
- Recent stability changes:
  - added a short speech-start debounce so one loud frame does not trigger a fake turn
  - drops too-short noise bursts
  - chunks TTS audio before sending to the watch
  - paces chunks slightly to avoid blasting one large WatchConnectivity payload

## Transcript History

The phone companion persists transcript sessions in `UserDefaults`.

- Data models live in `PhoneRealtimeBridge.swift`:
  - `PhoneTranscriptSession`
  - `PhoneTranscriptLine`
- Storage key: `WatchGPTPhone.transcriptSessions.v2`.
- Legacy migration reads `WatchGPTPhone.transcriptLines.v1` if present.
- Each started voice session creates a new transcript session titled either `Realtime chat` or `GPT-5.5 chat`.
- On the first user utterance, the title is replaced with a short title derived from the utterance.
- `PhoneContentView` shows session history, detail view, copy/share controls, individual swipe delete, and clear-all.

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

- API key lives only on the iPhone.
- Watch and iPhone apps both need to be running/reachable for live sessions.
- `WCSession.sendMessageData` is used for raw audio bytes.
- `WCSession.sendMessage` is used for compact control/text messages.
- `RealtimeMessageKey.type` is `"t"` and text is `"x"`.
- Audio format is 24 kHz PCM16 mono in both directions.
- Avoid adding haptics back into the watch voice session unless there is a very specific reason and on-device evidence that it does not destabilize the session.
- The assistant prompt explicitly says it has no visual/camera/screen/location/sensor access. This was added after it said things like "I can see you."

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

- GPT-5.5 mode has been twitchy on-device. The current mitigation is local VAD debounce plus short-burst dropping, but it still needs real watch testing.
- GPT-5.5 "never speaks back" was likely caused by sending synthesized speech as one huge `sendMessageData` payload. It is now chunked/paced, but verify on device.
- Realtime is still the smoother path. GPT-5.5 mode is turn-based and will never feel as immediate as `gpt-realtime`.
- The watch screen can still dim/off. Workout runtime helps process lifetime, not display brightness.
- If OpenAI rejects `gpt-5.5`, the user may not have API access to that model. The phone bridge should surface the API error.
- Background pickup is limited. If the iPhone app is force-quit, the watch cannot revive it.
- Reconnect during an in-flight turn can lose buffered audio. The UX should eventually surface "connection dropped, try again" more explicitly.
