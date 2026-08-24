# Security

## API keys

This build can embed your `OPENAI_API_KEY` directly into the **iPhone** companion app bundle for personal sideloading. The build default is read from `WatchGPTPhone/Config/LocalSecrets.xcconfig` and exposed via Info.plist. `LocalSecrets.xcconfig` and root `.env` are gitignored. A key entered in iPhone Settings is stored in Keychain and overrides the build default; legacy plaintext `UserDefaults` values are migrated and removed. The watch app holds no key — it only relays audio over `WatchConnectivity`.

**Do not distribute a build of this app.** Anyone who installs your `.ipa` or sideloaded `.app` can extract the embedded key. Sideload only to devices you personally control.

## Trust boundary

- iPhone: holds API key, holds WebSocket to OpenAI.
- Watch: no key, no internet path. Communicates only with the paired iPhone over Bluetooth.

Transcript history is stored in the iPhone app's Application Support directory with complete-until-first-authentication file protection. Audio and transcript content is still sent to OpenAI when you use the assistant, under the policy and retention settings of your own OpenAI account.

This is intentional — even if the watch app's bundle were extracted, no credential would be exposed. The iPhone bundle is the only sensitive artifact.

## Reporting issues

Please open a GitHub issue for security-sensitive design concerns without sharing live keys, tokens, or private conversations.
