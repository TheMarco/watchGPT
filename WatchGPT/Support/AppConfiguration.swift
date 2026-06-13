import Foundation

// `MicSensitivity` and `OutputVolume` live in Shared/AudioSupport.swift so the
// phone can reference them too.

enum AppConfiguration {
    static let automaticConversationKey = "automaticConversation"
    static let workoutRuntimeKey = "workoutRuntime"
    static let micSensitivityKey = "micSensitivity"
    static let outputVolumeKey = "outputVolume"
    static let voiceBargeInKey = "voiceBargeIn"
    static let maxStoredMessages = 24

    static var micSensitivity: MicSensitivity {
        let raw = UserDefaults.standard.string(forKey: micSensitivityKey) ?? MicSensitivity.default.rawValue
        return MicSensitivity(rawValue: raw) ?? .default
    }

    static var outputVolume: OutputVolume {
        let raw = UserDefaults.standard.string(forKey: outputVolumeKey) ?? OutputVolume.default.rawValue
        return OutputVolume(rawValue: raw) ?? .default
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            automaticConversationKey: true,
            workoutRuntimeKey: true,
            micSensitivityKey: MicSensitivity.default.rawValue,
            outputVolumeKey: OutputVolume.default.rawValue,
            voiceBargeInKey: false
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
