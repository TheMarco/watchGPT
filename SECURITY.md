# Security

## API keys

This build embeds your `OPENAI_API_KEY` directly into the **iPhone** companion app bundle for personal sideloading. The key is read from `WatchGPTPhone/Config/LocalSecrets.xcconfig` at build time and exposed via Info.plist. `LocalSecrets.xcconfig` and root `.env` are gitignored. The watch app holds no key — it only relays audio over `WatchConnectivity`.

**Do not distribute a build of this app.** Anyone who installs your `.ipa` or sideloaded `.app` can extract the embedded key. Sideload only to devices you personally control.

## Trust boundary

- iPhone: holds API key, holds WebSocket to OpenAI.
- Watch: no key, no internet path. Communicates only with the paired iPhone over Bluetooth.

This is intentional — even if the watch app's bundle were extracted, no credential would be exposed. The iPhone bundle is the only sensitive artifact.

## Reporting issues

Please open a GitHub issue for security-sensitive design concerns without sharing live keys, tokens, or private conversations.
