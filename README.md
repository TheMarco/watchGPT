# WatchGPT

Realtime ChatGPT voice for Apple Watch. Tap the main button, talk, hear the answer streamed back through the watch speaker. Two modes: **Fast Mode** (OpenAI's `gpt-realtime-2.1` for true streaming speech-to-speech) and **Think Mode** (a turn-based GPT-6 pipeline for cases where you want slower, deeper reasoning).

This is a **personal sideloading project**. There is no App Store build and there will not be one. You bring your own OpenAI API key, you build it yourself, you run it on your own watch.

You may wonder: "Why not?". There are several reasons: First of all, "bring your own API keys" is not end-user friendly. The alternative is me charging people for usage and I really don't want to deal with that kind of headache. Secondly, this app probably treads on Siri which Apple may reject it for. It also uses workout keep-alive to keep the screen on. Since it's not actually a workout app I'm anticipating Apple would give me a hard time about that as well.

## How it works

```text
Apple Watch  ──WatchConnectivity──  iPhone  ──wss──  OpenAI
   (mic / speaker)                  (bridge)         (model)
```

Two targets:

- **WatchGPT** (watchOS) — captures 24 kHz PCM from the mic, plays back streamed PCM, shows the main voice button / transcript UI.
- **WatchGPTPhone** (iOS) — holds the OpenAI WebSocket (or runs the Think Mode turn pipeline), persists transcripts, and relays audio over Bluetooth.

The watch cannot reliably open arbitrary outbound WebSockets on its own. That's a watchOS networking limitation, tested at length — `URLSessionWebSocketTask`, `URLSession+waitsForConnectivity`, and `NWConnection+NWProtocolWebSocket` all fail in different ways even when HTTPS data tasks succeed. The iPhone companion exists to sidestep this. **Both apps must be running and reachable** for a session.

## Features

- **Fast Mode** — OpenAI `gpt-realtime-2.1` by default, with `gpt-realtime-2.1-mini` as a lower-cost option. Semantic VAD and streaming speech-to-speech keep latency conversational.
- **Think Mode** — phone-side speech detection → transcription → Responses API (`gpt-6.1-sol` by default, with Astra, Terra, and Luna selectable) → GPT-Audio 1.5 speech → playback. Multi-second latency per turn, but deeper reasoning.
- **Web search in both modes — no extra keys.** Both modes use OpenAI's hosted `web_search` server-side: Think Mode calls the Responses API directly, and Fast Mode registers a single `web_search` function tool that proxies to the same backend.
- **Hands-free** by default. Push-to-talk available in watch settings.
- **Voice barge-in toggle.** Off by default — half-duplex with tap-to-interrupt for quieter, less-echoey conversations. Flip it on if you want to interrupt the assistant by talking.
- **38 languages.** Lock the assistant (and the transcription model) to a specific language, or leave it on Auto.
- **Mic sensitivity preset** — High / Standard / Low for noisy rooms.
- **Premium watch UI.** Rounded-square voice button, round watch artwork, phase-colored glow, iPhone reachability pill, polished transcript bubbles, and audio-reactive halo.
- **AOD-aware.** When the watch enters always-on dim mode, the main button switches to a calm grayscale look so phase colors don't go stale.
- **Transcript history** on the iPhone — every session is saved with generated title/summary, usage metadata, copy/share/delete actions, native swipe-to-delete, and iMessage-style chat-bubble detail view.
- **Companion diagnostics** — collapsible live panel with mode, turn-taking, last OpenAI event, reconnects, mic peak, and watch chunk counts.
- **Built-in Help and About** — colorful in-app guide, creator links, privacy notes, and license information.
- **Per-mode voices** to choose from in iPhone settings.
- **Idle auto-end.** Sessions tear down after 30 seconds of silence so battery and tokens don't drain when you walk away.
- **Workout runtime** keeps the watch process alive longer than a typical 30-second background tail.
- **API key never touches the watch.**

## Model policy

The app keeps model choices centralized and exposes the useful quality/cost tradeoffs in iPhone Settings:

| Workload | Default | Alternatives |
| --- | --- | --- |
| Fast Mode | [`gpt-realtime-2.1`](https://developers.openai.com/api/docs/models/gpt-realtime-2.1) | `gpt-realtime-2.1-mini` |
| Think Mode | [`gpt-6.1-sol`](https://developers.openai.com/api/docs/models/gpt-6.1-sol) | `gpt-6-astra` for maximum capability; `gpt-6.1-terra` for speed; `gpt-6-luna` for economy |
| Transcription | [`gpt-transcribe`](https://developers.openai.com/api/docs/models/gpt-transcribe) | Current recommended file transcription model |
| Think Mode speech | [`gpt-audio-1.5`](https://developers.openai.com/api/docs/models/gpt-audio-1.5) | Voice is selectable; audio is returned as PCM16 |

Fast Mode stays on GPT-Realtime 2.1 because it uses the Realtime API's current WebSocket protocol. GPT-Live 1 is a newer voice product with a different API and event flow; adopting it requires a separate voice architecture migration.

Request, tool-call, queue, turn, and session limits are deliberately bounded to reduce the chance of accidental API spend during a personal session.

## Requirements

- A Mac with Xcode 26 or newer (watchOS + iOS SDKs installed via Xcode → Settings → Components).
- Apple Watch running watchOS 11 or newer, paired with an iPhone running iOS 17 or newer.
- An Apple ID for code signing. A free personal team is fine for sideloading.
- An OpenAI API key with access to the models you select. Fast Mode defaults to `gpt-realtime-2.1`; Think Mode defaults to `gpt-6.1-sol`.
- Node.js 20+ for the configuration and repeatable build commands.
- Optional for source-layout changes: [Mint](https://github.com/yonaskolb/Mint) (`brew install mint`). The checked-in `Mintfile` pins XcodeGen 2.44.1 reproducibly.

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
brew install mint
npm run tools:bootstrap
npm run project:generate
```

`npm run project:verify` checks that the committed Xcode project matches `project.yml` and the current source tree without rewriting the working copy.

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
- **Watch**: tap the main button. iOS will ask for microphone access. Allow it.
- **HealthKit / workout**: see [why it asks](#why-the-watch-asks-for-workout-access) below.

If everything is wired up correctly, the watch shows "Connecting…" briefly and then "Listening". Talk.

## Settings

On the **watch**, hit the gear icon:

- **Hands-free conversation** — On = talk naturally; off = push and hold the main button to speak.
- **Mic sensitivity** — High (quiet rooms), Standard (default), Low (noisy rooms — TV, kids).
- **Voice barge-in** — Off (default) gives clean half-duplex with tap-to-interrupt. On lets you interrupt by talking.
- **Workout keep-alive** — On (default) uses `HKWorkoutSession` for longer process life and the always-on dim treatment. Off = `WKExtendedRuntimeSession` only.

On the **iPhone**, hit the gear icon:

- **OpenAI API key** — paste here to store a runtime override in the iPhone Keychain.
- **Default mode** — Fast Mode or Think Mode. The watch starts whichever mode is selected here.
- **Fast Mode model and voice** — choose Realtime 2.1 or Realtime 2.1 Mini and pick from 10 realtime voices. `marin` and `cedar` are strong defaults.
- **Fast Mode turn-taking** — Patient / Balanced / Quick semantic VAD eagerness.
- **Think Mode model, voice, and reasoning** — choose Astra / Sol / Terra / Luna, a speech voice, and the reasoning effort.
- **Transcription** — uses GPT Transcribe, OpenAI's current recommended model for recorded speech.
- **Assistant language** — Auto (matches what you speak, falls back to English when uncertain) or pin to one of 38 languages.

The iPhone companion main screen also includes **Help** and **About** shortcuts, plus a collapsible **Diagnostics** panel for live troubleshooting.

## Web search

The assistant fetches fresh information when you ask things like *"what's the latest…"*, *"current price of…"*, *"weather in…"*, or any time it would otherwise have to guess from training-time data. **No third-party API keys required** — the OpenAI key is the only one you set.

- **Think Mode** calls the Responses API with OpenAI's hosted `web_search` tool, executed server-side.
- **Fast Mode** registers a single `web_search` function tool. When the realtime model calls it, the iPhone proxies to the same Responses API + hosted `web_search` backend and feeds the synthesized answer back into the realtime turn. You'll briefly hear "Let me check…" while the lookup runs (typically 2-5 s).

## Why the watch asks for workout access

watchOS aggressively suspends third-party apps. Even with the audio background mode, a watch app's process can be reaped within tens of seconds of the user dropping their wrist or letting the screen dim. That kills the realtime audio session.

The most effective workaround Apple actually permits is starting a `HKWorkoutSession` (in this app, of activity type `mindAndBody`). A live workout session keeps the process running long enough to hold a conversation. **WatchGPT does not record any workout data, does not share anything to Health, and does not read any of your health data.** The session exists purely as a process-lifetime crutch, and it's torn down the moment you end the conversation. You can disable it in watch settings if you'd rather give up the lifetime extension.

## Privacy & bring-your-own-key

- Your OpenAI API key is never sent to the watch; the iPhone uses it only to authenticate requests to OpenAI.
- The watch holds no key, sends no requests to OpenAI directly, and only ever talks to your iPhone.
- Audio and transcripts go from your iPhone to OpenAI under your account — you pay for usage, you're bound by [OpenAI's usage policies](https://openai.com/policies/usage-policies/).
- Transcript history is saved as an atomically written, data-protected JSON file under the iPhone app's Application Support directory. Legacy `UserDefaults` history is migrated automatically.
- Transcript titles and summaries are generated through your OpenAI key after sessions end.
- There is no analytics, no telemetry, no remote logging. The only network traffic is `wss://api.openai.com/...` and `https://api.openai.com/...`.
- Because the iPhone build embeds your API key, **never share an `.ipa`** of this app with anyone. Treat the build like the key itself.

## Repeatable developer checks

The repository provides noninteractive commands for the shared `WatchGPTPhone` scheme:

```sh
npm run project:verify  # Verify generated-project consistency
npm run test:logic      # Run core logic and persistence tests on the host
npm run build           # Unsigned generic-device build
npm run analyze         # Unsigned static analysis
npm run test:build      # Compile the hosted test bundle without launching a simulator
WATCHGPT_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' npm run test:simulator
```

All Xcode commands use dedicated paths below `/tmp/watchgpt-derived-data`; they do not depend on signing credentials or the embedded API key. See [Development](docs/DEVELOPMENT.md) for details. GitHub Actions runs the same generation, build, analysis, and test checks.

## Known limitations

These are the rough edges. They're known, they have plausible causes, and pull requests are welcome.

- **Watch screen dims, audio keeps going.** When you drop your wrist on a Series 5 or later, the watch enters its always-on dim treatment for the app — screen visibly dimmed but the session keeps running thanks to `HKWorkoutSession`. The main button switches to a neutral grayscale look in this state so stale phase colors don't mislead. Lifting your wrist clears it instantly. Series 4 and earlier have no AOD; nothing software-side can change that.
- **First message is slower than later messages.** OpenAI's first response has no KV cache for your instructions, and a 1.25 s mic-suppression window lets the AEC (acoustic echo canceller) converge before the model can hear its own speaker output. Result: turn 1 is laggy; turns 2+ are smooth.
- **Think Mode is noticeably slower than Fast Mode.** Sequential pipeline (listen → transcribe → reason → synthesize → speak), plus an extra hop when web search runs. Expect multi-second latency per turn. It exists for cases where the smarter model matters more than feel.
- **Echo bleed in echoey rooms.** Even with AEC + the suppression window, hard surfaces and tiny watch speakers can still produce enough self-pickup that Fast Mode interrupts itself a few seconds in. The default of barge-in **off** mostly solves this; AirPods solve it completely (no acoustic loop at all).
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
