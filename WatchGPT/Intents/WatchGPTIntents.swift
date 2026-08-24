import AppIntents

// Lightweight Siri / Shortcuts entry point. It only foregrounds the app — the
// voice session is owned by `ContentView`'s `@StateObject` and still requires a
// reachable iPhone companion, so launching is the most an intent can reliably
// drive without holding session state.
struct OpenWatchGPTIntent: AppIntent {
    static let title: LocalizedStringResource = "Open WatchGPT"
    static let description = IntentDescription("Opens WatchGPT so you can start a voice conversation.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct WatchGPTShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWatchGPTIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Start \(.applicationName)",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Open WatchGPT",
            systemImageName: "mic.circle.fill"
        )
    }
}
