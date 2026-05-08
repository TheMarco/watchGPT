import Foundation

enum PhoneConfiguration {
    static let openAIAPIKeyKey = "openAIAPIKey"
    static let realtimeVoiceKey = "openAIRealtimeVoice"

    static let availableVoices = [
        "alloy",
        "ash",
        "ballad",
        "coral",
        "echo",
        "sage",
        "shimmer",
        "verse",
        "marin",
        "cedar"
    ]

    static let defaultRealtimeVoice = "marin"
    static let realtimeModel = "gpt-realtime"
    static let realtimeEagerness = "low"
    static let realtimeInstructions =
        "You are WatchGPT, a fast, warm realtime voice assistant running on Apple Watch. Speak naturally, keep replies concise unless asked for depth, and avoid long lists unless they are genuinely useful."

    private static let openAIAPIKeyInfoKey = "WATCHGPT_OPENAI_API_KEY"

    static var realtimeEndpointURL: URL? {
        URL(string: "wss://api.openai.com/v1/realtime?model=\(realtimeModel)")
    }

    static var defaultOpenAIAPIKey: String {
        bundleString(for: openAIAPIKeyInfoKey, fallback: "")
    }

    static var openAIAPIKey: String {
        let stored = UserDefaults.standard.string(forKey: openAIAPIKeyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return stored.isEmpty ? defaultOpenAIAPIKey : stored
    }

    static var realtimeVoice: String {
        let stored = UserDefaults.standard.string(forKey: realtimeVoiceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if stored.isEmpty || !availableVoices.contains(stored) {
            return defaultRealtimeVoice
        }

        return stored
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            openAIAPIKeyKey: defaultOpenAIAPIKey,
            realtimeVoiceKey: defaultRealtimeVoice
        ])
    }

    private static func bundleString(for key: String, fallback: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return fallback
        }

        return trimmed
    }
}
