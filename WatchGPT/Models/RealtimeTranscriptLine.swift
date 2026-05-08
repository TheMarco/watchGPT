import Foundation

struct RealtimeTranscriptLine: Identifiable, Equatable {
    enum Speaker {
        case user
        case assistant
    }

    let id = UUID()
    let speaker: Speaker
    let text: String
}

