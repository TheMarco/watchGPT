# WatchGPT

Realtime ChatGPT voice for Apple Watch. Tap the orb, talk, hear the answer streamed back through the watch speaker. Two modes: **Fast Mode** (OpenAI's `gpt-realtime` for true streaming speech-to-speech) and **Think Mode** (a turn-based `gpt-5.5` pipeline for cases where you want the smarter, slower reasoning model).

This is a **personal sideloading project**. There is no App Store build and there will not be one. You bring your own OpenAI API key, you build it yourself, you run it on your own watch.

## How it works

```text
Apple Watch  ──WatchConnectivity──  iPhone  ──wss──  OpenAI
   (mic / speaker)                  (bridge)         (model)
```

Two targets:

- **WatchGPT** (watchOS) — captures 24 kHz PCM from the mic, plays back streamed PCM, shows the orb / transcript UI.
- **WatchGPTPhone** (iOS) — holds the OpenAI WebSocket (or runs the Think Mode turn pipeline), persists transcripts, and relays audio over Bluetooth.

The watch cannot reliably open arbitrary outbound WebSockets on its own. That's a watchOS networking limitation, tested at length — `URLSessionWebSocketTask`, `URLSession+waitsForConnectivity`, and `NWConnection+NWProtocolWebSocket` all fail in different ways even when HTTPS data tasks succeed. The iPhone companion exists to sidestep this. **Both apps must be running and reachable** for a session.

## Features

- **Fast Mode** — OpenAI `gpt-realtime`, semantic VAD with barge-in. Streaming speech-to-speech, conversational latency.
- **Think Mode** — phone-side speech detection → transcription → Responses API (`gpt-5.5`, reasoning effort `low`) → TTS → playback. Multi-second latency per turn, but you get the smarter model.
- **Hands-free** by default. Push-to-talk available in watch settings.
- **Transcript history** on the iPhone — every session is saved with an auto-generated title, copy / share / delete actions, native swipe-to-delete with confirmation.
- **10 voices** to choose from in iPhone settings.
- **Workout runtime** keeps the watch process alive longer than a typical 30-second background tail.
- **API key never touches the watch.**

## Requirements

- A Mac with Xcode 26 or newer (watchOS + iOS SDKs installed via Xcode → Settings → Components).
- Apple Watch running watchOS 11 or newer, paired with an iPhone running iOS 17 or newer.
- An Apple ID for code signing. A free personal team is fine for sideloading.
- An OpenAI API key with access to `gpt-realtime`. If you want Think Mode, your account also needs access to `gpt-5.5`.
- Node.js 20+ (only for the helper script that bakes your API key into the build).
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) if you intend to add or rename source files.

## Install

### 1. Clone

```sh
git clone https://github.com/TheMarco/watchGPT.git
cd watchGPT
```

### 2. Provide your OpenAI API key

Create a root-level `.env` (gitignored):

```sh
echo "OPENAI_API_KEY=sk-..." > .env
```

Then bake it into the iPhone debug build:

```sh
npm run configure:phone
```

This writes `WatchGPTPhone/Config/LocalSecrets.xcconfig` (also gitignored). You can also skip the env file and paste the key into iPhone Settings at runtime — the in-app value overrides the baked default.

### 3. Open in Xcode

```sh
open WatchGPT.xcodeproj
```

If you ever change the file layout, regenerate the project:

```sh
xcodegen generate
```

### 4. Sign both targets

In Xcode, select the project, then for **both** targets (`WatchGPT` and `WatchGPTPhone`):

- Set **Team** under Signing & Capabilities to your personal Apple ID team.
- Change the **Bundle Identifier** to something unique to you (e.g. `dev.yourname.watchgpt` and `dev.yourname.watchgpt.phone`). Free personal teams reject the default bundle IDs.

If you change bundle IDs, also update `WKCompanionAppBundleIdentifier` in `WatchGPT/Info.plist` to point at your new phone bundle ID.

### 5. Build and run

- Select the **WatchGPTPhone** scheme.
- Choose your iPhone as the destination.
- Run. The watch app deploys automatically through Xcode and the Watch app catalog on your phone (it can take a couple of minutes the first time).

### 6. First-run permissions

- **iPhone**: leave the WatchGPT app open in the foreground the first time so it can activate `WCSession`.
- **Watch**: tap the orb. iOS will ask for microphone access. Allow it.
- **HealthKit / workout**: see [why it asks](#why-the-watch-asks-for-workout-access) below.

If everything is wired up correctly, the watch shows "Connecting…" briefly and then "Listening". Talk.

## Settings

On the **watch**, hit the gear icon:

- **Mode** — Fast Mode (default, `gpt-realtime`) or Think Mode (`gpt-5.5`).
- **Hands-free** — toggle. On = talk naturally; off = push and hold the orb to speak.
- **Workout runtime** — toggle. On (default) = use `HKWorkoutSession` for longer background life. Off = `WKExtendedRuntimeSession` only.
- **Speak replies** — toggle. Off mutes the speaker and makes it text-only.

On the **iPhone**, hit the gear icon:

- **OpenAI API key** — paste here to override the baked value.
- **Voice** — pick from 10 voices. `marin` and `cedar` sound best with `gpt-realtime`.

## Why the watch asks for workout access

watchOS aggressively suspends third-party apps. Even with the audio background mode, a watch app's process can be reaped within tens of seconds of the user dropping their wrist or letting the screen dim. That kills the realtime audio session.

The most effective workaround Apple actually permits is starting a `HKWorkoutSession` (in this app, of activity type `mindAndBody`). A live workout session keeps the process running long enough to hold a conversation. **WatchGPT does not record any workout data, does not share anything to Health, and does not read any of your health data.** The session exists purely as a process-lifetime crutch, and it's torn down the moment you end the conversation. You can disable it in watch settings if you'd rather give up the lifetime extension.

## Privacy & bring-your-own-key

- Your OpenAI API key never leaves your iPhone.
- The watch holds no key, sends no requests to OpenAI directly, and only ever talks to your iPhone.
- Audio and transcripts go from your iPhone to OpenAI under your account — you pay for usage, you're bound by [OpenAI's usage policies](https://openai.com/policies/usage-policies/).
- Transcript history is saved locally on the iPhone (in `UserDefaults`). Nothing is uploaded anywhere except the calls to OpenAI you explicitly trigger.
- There is no analytics, no telemetry, no remote logging. The only network traffic is `wss://api.openai.com/...` and `https://api.openai.com/...`.
- Because the iPhone build embeds your API key, **never share an `.ipa`** of this app with anyone. Treat the build like the key itself.

## Known limitations

These are the rough edges. They're known, they have plausible causes, and pull requests are welcome.

- **Watch screen dims, audio keeps going.** When the watch screen goes dark or you drop your wrist, the audio process keeps running (thanks to the workout runtime), but the display is at the mercy of normal watchOS behavior. Lifting your wrist usually re-wakes the screen and resyncs the UI. Sometimes the orb takes a beat to redraw.
- **First message is slower than later messages.** OpenAI's first response after `session.update` has no KV cache for your instructions and is genuinely slower than subsequent turns. On top of that, the watch suppresses mic input during the first 1.25 s of assistant playback to let the AEC (acoustic echo canceller) converge. Without this, the speaker output leaks into the mic and OpenAI's semantic VAD interrupts its own response. Result: turn 1 is laggy and may sound clipped at the very start; turns 2+ are smooth.
- **Think Mode is noticeably slower than Fast Mode.** It is not realtime — it's a sequential pipeline (listen → transcribe → reason → synthesize → speak). Expect multi-second latency per turn. It exists for cases where the smarter model matters more than feel.
- **Force-quitting the iPhone app breaks sessions.** If you swipe up the iPhone app, the watch's first tap will fail with "Open WatchGPT on your iPhone." Background suspension is fine; force-quit is not.
- **Off-wrist or locked behavior is poor.** The watch needs to be worn and unlocked. Off-wrist can trigger PIN prompts and suspend audio.
- **Reconnect during an in-flight turn loses the user's audio.** The phone-side bridge has exponential-backoff reconnect, but if the network drops mid-turn, your buffered speech is gone — talk again.
- **Sideload only.** This will never be on the App Store. If your provisioning profile expires, the app stops launching until you rebuild. With a free Apple ID, that's every 7 days.

## Reporting bugs

Please open issues on the [GitHub repo](https://github.com/TheMarco/watchGPT/issues). Useful things to include:

- Watch and iPhone model + OS versions.
- Which mode (Fast or Think) and which interaction style (hands-free or push-to-talk).
- A short description of what you did and what happened.
- If audio was involved, anything you can capture from Console.app filtered to `WatchGPT` while the watch was plugged in over the dev cable. The app logs reachability flips, runtime session expiry, and `beginTurn` ignores there.

PRs are welcome too. Keep the spirit: this is a hacker-friendly sideload project, not a polished SaaS.

## Credits

Built by **Marco van Hylckama Vlieg**.

- <https://ai-created.com/>
- Follow on X: <https://x.com/AIandDesign>

If you find this useful, a follow on X is a kind way to say thanks. Buying me a coffee is also lovely: <https://ko-fi.com/aianddesign>.

## License

This project is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).

You may use, copy, modify, and share this software for non-commercial purposes.

Commercial use is not permitted without a separate commercial license.
For commercial licensing, contact: info@ai-created.com
