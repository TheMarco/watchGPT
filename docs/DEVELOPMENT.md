# Development

WatchGPT keeps the generated Xcode project in source control so normal personal builds only need Xcode. Source-layout changes use XcodeGen 2.44.1, pinned through `Mintfile`.

## Tool bootstrap

Install Mint once, then bootstrap the pinned tools:

```sh
brew install mint
npm run tools:bootstrap
```

If XcodeGen 2.44.1 is already installed globally, the project scripts can use it without Mint. A different global XcodeGen version is rejected to keep generation deterministic.

## Project generation

```sh
npm run project:generate
npm run project:verify
```

`project:generate` rewrites `WatchGPT.xcodeproj` from `project.yml`. `project:verify` copies the working tree to a temporary directory, generates there, and compares the tracked project, workspace, and shared scheme files. It never rewrites the working copy.

Run generation after adding, removing, or renaming source files or changing `project.yml`. Commit the generated Xcode project with the source change.

## Build and test

```sh
npm run build
npm run analyze
npm run test:logic
npm run test:build
WATCHGPT_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' npm run test:simulator
```

The commands share the `WatchGPTPhone` scheme and disable code signing and SwiftUI preview products:

| Command | Destination | Derived data |
| --- | --- | --- |
| `npm run build` | Generic iOS device | `/tmp/watchgpt-derived-data/build` |
| `npm run analyze` | Generic iOS device | `/tmp/watchgpt-derived-data/analyze` |
| `npm run test:logic` | macOS host (Swift Package) | `/tmp/watchgpt-swiftpm` |
| `npm run test:build` | Generic iOS device SDK | `/tmp/watchgpt-derived-data/test-build` |
| `npm run test:simulator` | `WATCHGPT_TEST_DESTINATION` | `/tmp/watchgpt-derived-data/test` |

Use any available iPhone simulator in `WATCHGPT_TEST_DESTINATION`. List installed choices with:

```sh
xcrun simctl list devices available
```

Simulator execution requires CoreSimulatorService. The other commands do not launch a simulator or require a signing identity, though Xcode's watch asset compiler still expects the matching simulator platform components to be installed.

## Continuous integration

`.github/workflows/validate.yml` installs the pinned XcodeGen through Mint, verifies the generated project, performs the unsigned build and analysis, builds tests, chooses an available iPhone simulator, and runs the test bundle. It needs no API key or signing secret.
