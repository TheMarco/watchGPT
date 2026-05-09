import Foundation

enum MicSensitivity: String, CaseIterable, Identifiable {
    case high
    case standard
    case low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return "High (quiet rooms)"
        case .standard: return "Standard"
        case .low: return "Low (noisy rooms)"
        }
    }

    var inputGain: Float {
        switch self {
        case .high: return 5.5
        case .standard: return 4.0
        case .low: return 2.5
        }
    }

    static let `default`: MicSensitivity = .standard
}

enum AppConfiguration {
    static let automaticConversationKey = "automaticConversation"
    static let voiceEngineKey = "voiceEngine"
    static let workoutRuntimeKey = "workoutRuntime"
    static let speakRepliesKey = "speakReplies"
    static let micSensitivityKey = "micSensitivity"
    static let maxStoredMessages = 24

    static var micSensitivity: MicSensitivity {
        let raw = UserDefaults.standard.string(forKey: micSensitivityKey) ?? MicSensitivity.default.rawValue
        return MicSensitivity(rawValue: raw) ?? .default
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            automaticConversationKey: true,
            voiceEngineKey: VoiceEngine.realtime.rawValue,
            workoutRuntimeKey: true,
            speakRepliesKey: true,
            micSensitivityKey: MicSensitivity.default.rawValue
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
