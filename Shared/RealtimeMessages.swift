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

enum RealtimeMessageKey {
    static let type = "t"
    static let payload = "p"
    static let text = "x"
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
