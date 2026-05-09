import Foundation

enum AppConfiguration {
    static let automaticConversationKey = "automaticConversation"
    static let voiceEngineKey = "voiceEngine"
    static let workoutRuntimeKey = "workoutRuntime"
    static let speakRepliesKey = "speakReplies"
    static let maxStoredMessages = 24

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            automaticConversationKey: true,
            voiceEngineKey: VoiceEngine.realtime.rawValue,
            workoutRuntimeKey: true,
            speakRepliesKey: true
        ])
    }
}

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil {
            return defaultValue
        }

        return bool(forKey: key)
    }
}
