import Foundation

struct PhoneTranscriptLine: Identifiable, Codable, Equatable, Sendable {
    enum Speaker: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let date: Date
    let speaker: Speaker
    let text: String

    init(id: UUID = UUID(), date: Date = Date(), speaker: Speaker, text: String) {
        self.id = id
        self.date = date
        self.speaker = speaker
        self.text = text
    }
}

struct PhoneSessionUsage: Codable, Equatable, Sendable {
    var durationSeconds: Int = 0
    var audioChunksFromWatch: Int = 0
    var audioChunksToOpenAI: Int = 0
    var eventsFromOpenAI: Int = 0
    var webSearchCount: Int = 0
    var reconnectCount: Int = 0
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var totalTokens: Int = 0

    init(
        durationSeconds: Int = 0,
        audioChunksFromWatch: Int = 0,
        audioChunksToOpenAI: Int = 0,
        eventsFromOpenAI: Int = 0,
        webSearchCount: Int = 0,
        reconnectCount: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.durationSeconds = durationSeconds
        self.audioChunksFromWatch = audioChunksFromWatch
        self.audioChunksToOpenAI = audioChunksToOpenAI
        self.eventsFromOpenAI = eventsFromOpenAI
        self.webSearchCount = webSearchCount
        self.reconnectCount = reconnectCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
    }

    private enum CodingKeys: String, CodingKey {
        case durationSeconds
        case audioChunksFromWatch
        case audioChunksToOpenAI
        case eventsFromOpenAI
        case webSearchCount
        case reconnectCount
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case reasoningTokens
        case totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        audioChunksFromWatch = try container.decodeIfPresent(Int.self, forKey: .audioChunksFromWatch) ?? 0
        audioChunksToOpenAI = try container.decodeIfPresent(Int.self, forKey: .audioChunksToOpenAI) ?? 0
        eventsFromOpenAI = try container.decodeIfPresent(Int.self, forKey: .eventsFromOpenAI) ?? 0
        webSearchCount = try container.decodeIfPresent(Int.self, forKey: .webSearchCount) ?? 0
        reconnectCount = try container.decodeIfPresent(Int.self, forKey: .reconnectCount) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
    }
}

struct PhoneTranscriptSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    var endedAt: Date?
    var engine: VoiceEngine
    var title: String
    var summary: String?
    var usage: PhoneSessionUsage
    var lines: [PhoneTranscriptLine]

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case endedAt
        case engine
        case title
        case summary
        case usage
        case lines
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        endedAt: Date? = nil,
        engine: VoiceEngine = .realtime,
        title: String,
        summary: String? = nil,
        usage: PhoneSessionUsage = PhoneSessionUsage(),
        lines: [PhoneTranscriptLine] = []
    ) {
        self.id = id
        self.date = date
        self.endedAt = endedAt
        self.engine = engine
        self.title = title
        self.summary = summary
        self.usage = usage
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        engine = try container.decodeIfPresent(VoiceEngine.self, forKey: .engine) ?? .realtime
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        usage = try container.decodeIfPresent(PhoneSessionUsage.self, forKey: .usage) ?? PhoneSessionUsage()
        lines = try container.decode([PhoneTranscriptLine].self, forKey: .lines)
    }
}
