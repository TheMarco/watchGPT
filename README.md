# WatchGPT

Realtime ChatGPT voice for Apple Watch. Speak naturally, interrupt mid-reply, hear streamed audio back.

The watchOS app captures and plays audio. An iOS companion app holds the OpenAI Realtime WebSocket and relays audio to the watch over Bluetooth (`WatchConnectivity`). The iPhone is required at runtime — watchOS networking does not allow a third-party app to open the outbound WebSocket itself.

This repo is built for sideloading and personal hacking. **Do not distribute a build of this app** — it embeds your OpenAI API key.

## What is included

- A SwiftUI watchOS app for mic capture, audio playback, transcript display.
- A SwiftUI iOS companion app that holds the OpenAI Realtime WebSocket and relays audio.
- 24 kHz PCM streaming over `WatchConnectivity` (watch ↔ iPhone) and over WSS (iPhone ↔ OpenAI).
- Realtime speech-to-speech via OpenAI's `gpt-realtime-2` model with `reasoning.effort: low`.
- Streaming assistant audio playback and barge-in interruption.
- XcodeGen project file so contributors can regenerate the Xcode project.

## Architecture

```text
Apple Watch ──WC (Bluetooth)── iPhone ──wss── OpenAI Realtime
```

The OpenAI API key lives only on the iPhone. The watch never sees it.

## Requirements

- macOS with Xcode 26 or newer.
- watchOS and iOS platforms installed in Xcode Settings → Components.
- XcodeGen (`brew install xcodegen`) if you regenerate the Xcode project.
- Node.js 20 or newer for the `configure:phone` helper.
- An OpenAI API key with access to `gpt-realtime-2`.
- An Apple Watch (paired with iPhone, or Apple Watch Ultra cellular — note: even Ultra needs the iPhone companion for this app).

## Quick start

1. Put your OpenAI key in a root-level `.env` (gitignored):

   ```sh
   echo "OPENAI_API_KEY=sk-your-key-here" > .env
   ```

2. Bake it into the iPhone debug build:

   ```sh
   npm run configure:phone
   ```

3. Regenerate the Xcode project if needed:

   ```sh
   xcodegen generate
   ```

4. Open `WatchGPT.xcodeproj` in Xcode.

5. Set your Apple Development Team on **both** the `WatchGPT` (watch) and `WatchGPTPhone` (iOS) targets.

6. Select the `WatchGPTPhone` scheme and run on your iPhone. The watch app installs alongside.

7. On the iPhone, open WatchGPT (it must be in the foreground for sessions to work). On the watch, tap the orb.

## Voice flow

- Open WatchGPT on iPhone (foreground).
- Tap the orb on the watch.
- Watch sends a `start` message to iPhone over `WatchConnectivity`.
- iPhone opens the WebSocket to OpenAI Realtime.
- Watch streams 24 kHz PCM mic audio to iPhone, iPhone forwards to OpenAI.
- OpenAI streams audio deltas back. iPhone forwards to watch. Watch plays them through `AVAudioPlayerNode`.
- Start talking while the assistant is speaking to interrupt — OpenAI handles `interrupt_response`.
- Tap the orb again to end the session.

## Notes

- `LocalSecrets.xcconfig` and root `.env` are gitignored. Don't commit either.
- The iPhone app must be in the foreground while you use the watch app. If iPhone is suspended, the first watch tap will surface "Open WatchGPT on your iPhone."
- You can also paste an API key in iPhone Settings; UserDefaults overrides the baked default.

## Verification

```sh
# Watch target
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

# iPhone target
xcrun --sdk iphoneos swiftc -typecheck \
  Shared/RealtimeMessages.swift \
  WatchGPTPhone/WatchGPTPhoneApp.swift \
  WatchGPTPhone/Support/PhoneConfiguration.swift \
  WatchGPTPhone/Views/PhoneContentView.swift \
  WatchGPTPhone/Views/PhoneSettingsView.swift \
  WatchGPTPhone/Services/PhoneRealtimeBridge.swift \
  -target arm64-apple-ios17.0
```

Full Xcode builds require the watchOS and iOS platform components installed.
