# WatchGPT

Realtime ChatGPT voice for Apple Watch. **Two-target SwiftUI project**: a watchOS app captures/plays audio, an iOS companion app holds the OpenAI Realtime WebSocket. They talk over `WatchConnectivity`. Sideload only — never distribute a build (the iPhone build embeds your live API key).

Repo: https://github.com/TheMarco/watchGPT (public).

## Why two targets

The watchOS networking stack does not let third-party apps open arbitrary outbound TLS WebSockets — empirically tested with `URLSessionWebSocketTask`, `URLSession+waitsForConnectivity`, and `NWConnection+NWProtocolWebSocket`. All fail (`-1009`, `cancelled`, or `ENETDOWN [POSIX 50]`) even with the watch on its own cellular and Apple's apps clearly passing data. HTTPS data tasks succeed because they're routed through Apple-managed paths a WS task cannot use. The iPhone target sidesteps this entirely by holding the WebSocket and relaying audio over Bluetooth.

## UX

Push-to-talk. The watch shows a big orb. **Hold the orb to talk, release to send**. Quick tap from `disconnected` starts the session; quick tap from `speaking` interrupts the AI and immediately starts a new turn. We deliberately do not use OpenAI's server VAD — repeated lockups (mic feedback re-triggering VAD, "stuck listening forever") made it unreliable.

Phase state machine on the watch:
```
disconnected → connecting → connected ⇄ listening
                              ↑           ↓
                              speaking ←──/
```

## Layout

- `WatchGPT/` — watchOS target (Swift 5, deploymentTarget 11.0)
  - `WatchGPTApp.swift` — entry point; `AppConfiguration.registerDefaults()`
  - `Views/`
    - `ContentView.swift` — orb + transcript + stop button. Orb uses `onLongPressGesture(minimumDuration: 0, onPressingChanged:)` (DragGesture's `onEnded` was unreliable).
    - `SettingsView.swift`, `RealtimeTranscriptBubble.swift`
  - `Services/`
    - `RealtimeVoiceSession` — `WCSession` client + phase machine. Sends `start`/`stop`/`commit`/audio to phone, receives audio + events back. Watchdog timer + audio-engine restart logic live here.
    - `RealtimeAudioIO` — `AVAudioEngine` mic capture (24 kHz PCM16) + `AVAudioPlayerNode` playback. Manual Float32→Int16 conversion (AVAudioConverter produced all zeros on watchOS); `.measurement` mode with `inputGain=4.0`, `outputGain=2.0`. `isEngineRunning` and `restartIfNeeded()` for recovery.
  - `Models/RealtimeTranscriptLine.swift`
  - `Support/AppConfiguration.swift` — minimal: `speakReplies` toggle, `maxStoredMessages`. **No API key on the watch.**
  - `Config/WatchGPT.xcconfig` — committed; intentionally empty.
  - `Info.plist` — mic usage, `WKApplication`, `WKCompanionAppBundleIdentifier = dev.watchgpt.app`, `WKBackgroundModes: audio`.
- `WatchGPTPhone/` — iOS target (Swift 5, deploymentTarget 17.0)
  - `WatchGPTPhoneApp.swift` — entry; activates `PhoneRealtimeBridge` on launch.
  - `Views/` — `PhoneContentView` (status + counters), `PhoneSettingsView` (API key, voice picker).
  - `Services/PhoneRealtimeBridge.swift` — `WCSessionDelegate` ↔ OpenAI `URLSessionWebSocketTask`. Auto-reconnect with exponential backoff, 10s ping watchdog, keep-alive AVAudioSession.
  - `Support/PhoneConfiguration.swift` — API key plumbing (UserDefaults → bundle default), realtime constants (model `gpt-realtime`, default voice `marin`, instruction string), endpoint URL builder, voice picker list.
  - `Config/WatchGPTPhone.xcconfig` — committed; falls through to `LocalSecrets.xcconfig` (gitignored).
  - `Info.plist` — `WATCHGPT_OPENAI_API_KEY` from xcconfig, `UIBackgroundModes: audio`.
- `Shared/RealtimeMessages.swift` — message envelope, compiled into both targets.
- `scripts/configure-phone.js` — reads `./.env` or `OPENAI_API_KEY` env, writes `WatchGPTPhone/Config/LocalSecrets.xcconfig`.
- `scripts/configure-watch.js` — historical, watch xcconfig is empty by design. Don't use it.
- `project.yml` — XcodeGen spec. `WatchGPTPhone` embeds `WatchGPT`. Run `xcodegen generate` after structural changes.

## Architecture

```
[Watch app] ──WC sendMessage / sendMessageData (Bluetooth)── [iPhone app] ──WSS── [OpenAI Realtime]
```

- Watch captures mic at 24 kHz PCM16, sends each chunk via `WCSession.sendMessageData` (raw bytes, dedicated channel).
- iPhone base64-encodes audio, forwards as `input_audio_buffer.append`.
- On orb release, watch sends `.commit` (`sendMessage`); phone emits `input_audio_buffer.commit` + `response.create`.
- iPhone receives OpenAI events. Audio deltas → `sendMessageData(audio)` back to watch (buffered to ~19,200 bytes for smoothness). Transcript / state events → `sendMessage([type:…])`.
- We do **not** use OpenAI's `turn_detection` — set to `NSNull()`. Half-duplex by design.

## Resilience layers (added because the underlying transports drop)

### Watch side (`RealtimeVoiceSession`)

- **Watchdog** runs every 2s while connected:
  - `.speaking` for >6s past `playbackEndsAt` → force `.connected`
  - `.connecting` for >12s → fail with error
  - `.listening` for >60s → force `.connected`
- **Response timeout**: on commit, stamp `awaitingResponseSince`. Cleared on any sign of life from OpenAI. >12s with no signal → "No reply from iPhone…" error.
- **`WKExtendedRuntimeSession` auto-restart** on expiry. Without this the watch dims and the audio engine dies.
- **`beginTurn` is robust**: auto-recovers from `.speaking`/`.connecting`, force-restarts the audio session, then enters `.listening`. Lets you interrupt the AI mid-reply with one press.
- **Late-audio guard**: `handlePhoneAudio` drops chunks if `phase == .listening` (otherwise interrupts bounce back to `.speaking`).
- **`isReachable` is advisory, not fatal.** WC reachability flickers spuriously even when both apps are healthy. We log changes but never tear down on it.

### iPhone side (`PhoneRealtimeBridge`)

- **Auto-reconnect with exponential backoff**: `handleSocketLost(reason:)` is the single recovery path used by the receive loop, the ping task, and `commitUserTurn`. Backoff 1s → 2s → 4s → 8s, max 4 attempts. `reconnectAttempts` reset on `session.created`. During reconnect, counters are preserved.
- **Ping watchdog**: 10s `sendPing` against the WS. Detects half-open TCP sockets that `URLSessionWebSocketTask` won't notice on its own.
- **Keep-alive**: `UIBackgroundModes: audio` + an active `AVAudioSession` (`.playback`, `mixWithOthers`) + `isIdleTimerDisabled = true` while a session is live. The audio entitlement alone does nothing — you must actually hold an audio session for iOS to keep the app foreground-equivalent.
- **Voice change mid-session**: `UserDefaults.didChangeNotification` observer triggers a fresh `session.update` if the picker value changed and we're connected (`lastSentVoice` tracks the active value).
- **`URLSession` timeouts tuned for streaming**: `timeoutIntervalForRequest = 90`, `timeoutIntervalForResource = 86400`. The default 30s killed long-lived WS frames during silence.

## Invariants

- **API key lives only on the iPhone.** Watch has no key plumbing.
- **Both apps must be running for a session.** `WCSession.sendMessage`/`sendMessageData` are foreground-to-foreground. The keep-alive on iPhone is what makes long sessions practical.
- **Message envelope**: `RealtimeMessage.encode(_:payload:)` → `[String: Any]` keyed by `RealtimeMessageKey.type` (`"t"`) and `RealtimeMessageKey.text` (`"x"`). Audio is raw `Data` via `sendMessageData` — never wrapped.
- **Audio format**: 24 kHz PCM16 mono both directions.

## Commands

```sh
# bake the API key into the iPhone debug build (reads ./.env or OPENAI_API_KEY env)
npm run configure:phone

# regenerate the Xcode project after adding/removing .swift files or editing project.yml
xcodegen generate

# typecheck watch target
xcrun --sdk watchos swiftc -typecheck \
  Shared/RealtimeMessages.swift \
  WatchGPT/WatchGPTApp.swift \
  WatchGPT/Support/AppConfiguration.swift \
  WatchGPT/Models/RealtimeTranscriptLine.swift \
  WatchGPT/Services/RealtimeAudioIO.swift \
  WatchGPT/Services/RealtimeVoiceSession.swift \
  WatchGPT/Views/ContentView.swift \
  WatchGPT/Views/RealtimeTranscriptBubble.swift \
  WatchGPT/Views/SettingsView.swift \
  -target arm64-apple-watchos11.0

# typecheck iPhone target
xcrun --sdk iphoneos swiftc -typecheck \
  Shared/RealtimeMessages.swift \
  WatchGPTPhone/WatchGPTPhoneApp.swift \
  WatchGPTPhone/Support/PhoneConfiguration.swift \
  WatchGPTPhone/Views/PhoneContentView.swift \
  WatchGPTPhone/Views/PhoneSettingsView.swift \
  WatchGPTPhone/Services/PhoneRealtimeBridge.swift \
  -target arm64-apple-ios17.0
```

CI workflow at `.github/workflows/ci.yml` was removed because the local `gh` token lacks `workflow` scope. Re-add it via:

```sh
gh auth refresh -s workflow
# then restore the file (it ran both typechecks on macos-latest) and push
```

## Conventions / gotchas

- `LocalSecrets.xcconfig`, `.env`, and `.claude/` are gitignored. Never commit secrets.
- The watch's xcconfig is intentionally empty — if you find yourself adding the API key there, you've crossed a trust boundary.
- After adding/removing `.swift` files, run `xcodegen generate`. The pbxproj has explicit refs.
- Both apps need `WCSession.activate()` at launch. We do this in their `App.init` paths via the bridge / session.
- `WCSession.sendMessage` errors don't surface to the recipient. Use `errorHandler:` on the sender for visibility.
- `sendMessageData` is for binary; `sendMessage([String: Any])` is for control + text. Don't try to wrap audio in a dict — the dedicated channel exists for a reason.
- `RealtimeVoiceSession` and `PhoneRealtimeBridge` handle both old and new OpenAI realtime event names (`response.audio.delta` ↔ `response.output_audio.delta`). Don't drop one set without testing.
- The model is `gpt-realtime` (not `gpt-realtime-2` — that one isn't available on most accounts).
- Voice picker has 10 voices; OpenAI recommends `marin` or `cedar` for `gpt-realtime`.
- Watch logs lifecycle to console (runtime session expiry, reachability flips, `beginTurn` ignores). Plug the watch in and use Console.app filtered by "WatchGPT" when debugging.
- This is a personal sideloading project. The iPhone build embeds your live API key — never distribute the .ipa.

## Known weak points / future work

- **Interrupting mid-reply doesn't tell OpenAI to stop.** Pressing the orb during `.speaking` recovers the watch and the late-audio guard discards stragglers, but OpenAI keeps generating server-side until it wraps. A `.cancel` message + phone-side `response.cancel` would clean this up.
- **Reconnect during an in-flight turn** loses the user's audio buffer — they have to talk again. The watch could detect a `.ready` while in `.listening` and surface "Disconnected — try again", but currently it just resets phase.
- **No iPhone background pickup**: if the iPhone app is force-quit (not just backgrounded), the first watch `start` will fail with reachability. The keep-alive prevents normal background suspension, but not a manual swipe-up kill.
