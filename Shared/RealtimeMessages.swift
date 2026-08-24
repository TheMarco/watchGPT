import Foundation

enum RealtimeMessageType: String {
    case start
    case stop
    case commit
    case cancelTurn
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
    case connectionStatus
}

enum VoiceEngine: String, CaseIterable, Codable, Sendable {
    case realtime
    case gpt5

    var displayName: String {
        switch self {
        case .realtime:
            return "Fast Mode"
        case .gpt5:
            return "Think Mode"
        }
    }

    var modelDescription: String {
        switch self {
        case .realtime:
            return "OpenAI Realtime · streaming speech"
        case .gpt5:
            return "GPT-5.6 · deeper reasoning"
        }
    }
}

enum RealtimeMessageKey {
    static let type = "t"
    static let payload = "p"
    static let text = "x"
    static let sessionID = "s"
    static let sequence = "q"
    static let automaticTurnDetection = "a"
    static let voiceEngine = "e"
    static let micSensitivity = "m"
}

enum RealtimeMessage {
    static func encode(
        _ type: RealtimeMessageType,
        sessionID: UUID? = nil,
        sequence: UInt64? = nil,
        payload: [String: Any] = [:]
    ) -> [String: Any] {
        var dict: [String: Any] = [RealtimeMessageKey.type: type.rawValue]
        if let sessionID {
            dict[RealtimeMessageKey.sessionID] = sessionID.uuidString
        }
        if let sequence {
            dict[RealtimeMessageKey.sequence] = NSNumber(value: sequence)
        }
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

    static func sessionID(of message: [String: Any]) -> UUID? {
        guard let raw = message[RealtimeMessageKey.sessionID] as? String else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func sequence(of message: [String: Any]) -> UInt64? {
        if let number = message[RealtimeMessageKey.sequence] as? NSNumber {
            return number.uint64Value
        }
        if let value = message[RealtimeMessageKey.sequence] as? UInt64 {
            return value
        }
        return nil
    }
}

/// WatchConnectivity delivers property-list dictionaries through an Objective-C
/// delegate that predates Swift concurrency. The framework does not mutate a
/// received message after callback delivery, so this wrapper safely transfers
/// that immutable snapshot to the main actor.
struct RealtimeControlMessage: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}
