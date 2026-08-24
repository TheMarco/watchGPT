# Install and Run

WatchGPT has two targets: a watchOS app and an iOS companion. The iPhone companion holds the OpenAI Realtime WebSocket; the watch relays audio over `WatchConnectivity`. The OpenAI key is embedded in the iPhone build for personal sideloading. Do not distribute a build.

## 1. Provide your OpenAI key

```sh
cd watchGPT
echo "OPENAI_API_KEY=sk-your-key-here" > .env
npm run configure:phone
```

This writes `WatchGPTPhone/Config/LocalSecrets.xcconfig` (gitignored). The iPhone build picks the value up via `WatchGPTPhone.xcconfig` → Info.plist (`WATCHGPT_OPENAI_API_KEY`).

You can also pass the key inline:

```sh
OPENAI_API_KEY=sk-... npm run configure:phone
```

## 2. Install both apps

1. Install the watchOS and iOS platforms in Xcode → Settings → Components.

2. Open:

   ```text
   /Users/marcovhv/projects/GIT/watchGPT/WatchGPT.xcodeproj
   ```

3. Set your Apple Development Team on **both** targets:
   - `WatchGPT` (watchOS)
   - `WatchGPTPhone` (iOS)

4. Select the `WatchGPTPhone` scheme.

5. Choose your iPhone as the run destination.

6. Press Run. The watch app installs alongside the iPhone app automatically.

## 3. Use it

- Open WatchGPT on the iPhone and keep it in the foreground.
- On the watch, open WatchGPT and tap the main button.
- Speak naturally; interrupt by speaking while the assistant talks.

If the watch shows "Open WatchGPT on your iPhone," the iPhone app got suspended in the background. Reopen it and try again.

## Overriding the key at runtime

Open WatchGPT on the iPhone → tap the gear → enter a key. The runtime override is stored in Keychain and takes precedence over the baked-in default. "Reset to build default" removes the Keychain override and restores whatever was baked.

## Regenerating and validating the project

The committed Xcode project is generated with XcodeGen 2.44.1, pinned in `Mintfile`:

```sh
brew install mint
npm run tools:bootstrap
npm run project:generate
npm run project:verify
```

Normal sideload installation does not require regeneration. Use these commands after changing `project.yml` or the source-file layout. Repeatable unsigned build, analysis, and test commands are documented in [Development](DEVELOPMENT.md).

## Why an iPhone companion

watchOS does not let a third-party app open an outbound TLS WebSocket directly — empirically `URLSessionWebSocketTask`, `URLSession+waitsForConnectivity`, and `NWConnection+NWProtocolWebSocket` all fail (`-1009`, `cancelled`, `ENETDOWN`) even on Apple Watch Ultra cellular with Apple's own apps proving the network path works. The iPhone holds the WebSocket and relays.
