import Foundation

enum RealtimeMessageType: String {
    case start
    case stop
    case commit
    case audioFromWatch
    case audioFromPhone
    case ready
    case speechStarted
    case speechStopped
    case userTranscript
    case assistantTranscriptDelta
    case assistantTranscriptFinal
    case responseDone
    case error
    case watchAudioLevel
}

enum VoiceEngine: String, CaseIterable {
    case realtime
    case gpt5

    var displayName: String {
        switch self {
        case .realtime:
            return "Realtime"
        case .gpt5:
            return "GPT-5.5"
        }
    }
}

enum RealtimeMessageKey {
    static let type = "t"
    static let payload = "p"
    static let text = "x"
    static let automaticTurnDetection = "a"
    static let voiceEngine = "e"
}

enum RealtimeMessage {
    static func encode(_ type: RealtimeMessageType, payload: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = [RealtimeMessageKey.type: type.rawValue]
        for (key, value) in payload {
            dict[key] = value
        }
        return dict
    }

    static func type(of message: [String: Any]) -> RealtimeMessageType? {
        guard let raw = message[RealtimeMessageKey.type] as? String else {
            return nil
        }
        return RealtimeMessageType(rawValue: raw)
    }
}
