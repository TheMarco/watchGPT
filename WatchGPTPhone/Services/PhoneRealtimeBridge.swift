import AVFoundation
import Foundation
import UIKit
import WatchConnectivity

enum WebSearchError: LocalizedError {
    case http(Int, String)
    case decode
    case timeout

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Lookup HTTP \(code)\(trimmed.isEmpty ? "" : ": \(trimmed.prefix(180))")"
        case .decode: return "Lookup response could not be decoded."
        case .timeout: return "Lookup timed out."
        }
    }
}

struct PhoneTranscriptLine: Identifiable, Codable, Equatable {
    enum Speaker: String, Codable {
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

struct PhoneSessionUsage: Codable, Equatable {
    var durationSeconds: Int = 0
    var audioChunksFromWatch: Int = 0
    var audioChunksToOpenAI: Int = 0
    var eventsFromOpenAI: Int = 0
    var webSearchCount: Int = 0
    var reconnectCount: Int = 0
}

struct PhoneTranscriptSession: Identifiable, Codable, Equatable {
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

@MainActor
final class PhoneRealtimeBridge: NSObject, ObservableObject {
    static let shared = PhoneRealtimeBridge()

    @Published private(set) var statusText = "Idle"
    @Published private(set) var isActive = false
    @Published private(set) var audioChunksFromWatch = 0
    @Published private(set) var audioChunksToOpenAI = 0
    @Published private(set) var eventsFromOpenAI = 0
    @Published private(set) var lastAudioPeak: Int16 = 0
    @Published private(set) var lastWatchInputPeak: Float = 0
    @Published private(set) var transcriptSessions: [PhoneTranscriptSession] = []
    @Published private(set) var webSearchCount = 0
    @Published private(set) var reconnectCount = 0
    @Published private(set) var lastOpenAIEventType = "none"
    @Published private(set) var lastReconnectMessage: String?

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config)
    }()

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 4
    private var wcSession: WCSession?
    private var pendingAssistantAudio = Data()
    private let pendingAssistantFlushBytes = 9_600
    private var lastSentVoice = ""
    private var lastSentLanguage: AssistantLanguage = .auto
    private var lastSentVADEagerness: RealtimeVADEagerness = .low
    private var automaticTurnDetectionEnabled = true
    private var activeVoiceEngine: VoiceEngine = .realtime
    private var regularAudioBuffer = Data()
    private var regularPreSpeechBuffer = Data()
    private var regularSilentBytes = 0
    private var regularSpeechCandidateBytes = 0
    private var regularSpeechActive = false
    private var regularTurnInProgress = false
    private var regularTurnTask: Task<Void, Never>?
    private var regularConversationContext: [String] = []
    private let regularSpeechThreshold: Int16 = 1_400
    private let regularSpeechStartBytes = 9_600
    private let regularSilenceBytes = 52_800
    private let regularMinimumSpeechBytes = 12_000
    private let watchAudioChunkBytes = 9_600
    private let transcriptStorageKey = "WatchGPTPhone.transcriptSessions.v2"
    private let legacyTranscriptStorageKey = "WatchGPTPhone.transcriptLines.v1"
    private let maxStoredTranscriptLines = 400
    private let maxStoredTranscriptSessions = 50
    private var activeTranscriptSessionID: UUID?
    private var activeSessionStartedAt = Date()
    private var activeSessionWebSearchStart = 0
    private var activeSessionReconnectStart = 0
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        wcSession = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        loadTranscriptLines()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func activate() {
        guard let wcSession else {
            statusText = "WatchConnectivity unavailable"
            return
        }
        wcSession.delegate = self
        wcSession.activate()
        statusText = "Waiting for watch"

        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.applyVoiceChangeIfNeeded()
                }
            }
        }
    }

    private func startSession(engine: VoiceEngine, automaticTurnDetection: Bool) {
        activeVoiceEngine = engine
        switch engine {
        case .realtime:
            startRealtime(automaticTurnDetection: automaticTurnDetection)
        case .gpt5:
            startRegularVoice()
        }
    }

    private func startRealtime(automaticTurnDetection: Bool) {
        guard webSocket == nil else {
            automaticTurnDetectionEnabled = automaticTurnDetection
            return
        }

        automaticTurnDetectionEnabled = automaticTurnDetection
        let isReconnecting = reconnectAttempts > 0
        if !isReconnecting {
            audioChunksFromWatch = 0
            audioChunksToOpenAI = 0
            eventsFromOpenAI = 0
            webSearchCount = 0
            reconnectCount = 0
            lastOpenAIEventType = "none"
            lastReconnectMessage = nil
        }
        pendingAssistantAudio = Data()

        let apiKey = PhoneConfiguration.openAIAPIKey

        guard !apiKey.isEmpty else {
            sendErrorToWatch("OpenAI API key not configured on iPhone.")
            return
        }

        guard let endpoint = PhoneConfiguration.realtimeEndpointURL else {
            sendErrorToWatch("Invalid realtime endpoint URL.")
            return
        }

        if !isReconnecting {
            startTranscriptSession(engine: .realtime)
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = urlSession.webSocketTask(with: request)
        webSocket = task
        task.resume()

        statusText = "Connecting to OpenAI"
        isActive = true

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }

        beginKeepAlive()
    }

    private func startRegularVoice() {
        guard !isActive else {
            sendToWatch(.ready, payload: [RealtimeMessageKey.voiceEngine: activeVoiceEngine.rawValue])
            return
        }

        guard !PhoneConfiguration.openAIAPIKey.isEmpty else {
            sendErrorToWatch("OpenAI API key not configured on iPhone.")
            return
        }

        audioChunksFromWatch = 0
        audioChunksToOpenAI = 0
        eventsFromOpenAI = 0
        webSearchCount = 0
        reconnectCount = 0
        lastOpenAIEventType = "none"
        lastReconnectMessage = nil
        regularAudioBuffer = Data()
        regularPreSpeechBuffer = Data()
        regularSilentBytes = 0
        regularSpeechCandidateBytes = 0
        regularSpeechActive = false
        regularTurnInProgress = false
        regularConversationContext = []
        startTranscriptSession(engine: .gpt5)
        statusText = "Think Mode"
        isActive = true
        beginKeepAlive()
        sendToWatch(.ready, payload: [RealtimeMessageKey.voiceEngine: activeVoiceEngine.rawValue])
    }

    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true, options: [])
        } catch {
            print("[WatchGPTPhone] AVAudioSession activation failed: \(error)")
        }
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { return }
            await sendPing()
        }
    }

    private func sendPing() async {
        guard let webSocket else { return }
        await withCheckedContinuation { continuation in
            webSocket.sendPing { [weak self] error in
                if let error {
                    Task { @MainActor [weak self] in
                        self?.handleSocketLost(reason: "ping failed: \(error.localizedDescription)")
                    }
                }
                continuation.resume()
            }
        }
    }

    private func stopRealtime() {
        finalizeActiveTranscriptSession()
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        pendingAssistantAudio = Data()
        lastSentVoice = ""
        lastSentLanguage = .auto
        lastSentVADEagerness = .low
        regularTurnTask?.cancel()
        regularTurnTask = nil
        regularAudioBuffer = Data()
        regularPreSpeechBuffer = Data()
        regularSilentBytes = 0
        regularSpeechCandidateBytes = 0
        regularSpeechActive = false
        regularTurnInProgress = false
        regularConversationContext = []
        activeTranscriptSessionID = nil
        statusText = "Waiting for watch"
        isActive = false
        endKeepAlive()
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocket else {
                break
            }

            do {
                let message = try await webSocket.receive()
                try handleOpenAIMessage(message)
            } catch {
                if !Task.isCancelled {
                    handleSocketLost(reason: error.localizedDescription)
                }
                break
            }
        }
    }

    private func handleSocketLost(reason: String) {
        print("[WatchGPTPhone] socket lost: \(reason)")

        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        pendingAssistantAudio = Data()
        lastSentVoice = ""
        lastSentLanguage = .auto
        lastSentVADEagerness = .low

        guard isActive else { return }

        guard reconnectAttempts < maxReconnectAttempts else {
            sendErrorToWatch("Realtime disconnected after retries: \(reason). Tap stop, start again, and repeat your last request.")
            stopRealtime()
            return
        }

        reconnectAttempts += 1
        reconnectCount += 1
        lastReconnectMessage = reason
        statusText = "Reconnecting (\(reconnectAttempts)/\(maxReconnectAttempts))…"
        sendToWatch(.connectionStatus, text: statusText)

        let delay = pow(2.0, Double(reconnectAttempts - 1))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isActive else { return }
                self.startRealtime(automaticTurnDetection: self.automaticTurnDetectionEnabled)
            }
        }
    }

    private func handleOpenAIMessage(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data

        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            guard let valueData = value.data(using: .utf8) else {
                return
            }
            data = valueData
        @unknown default:
            return
        }

        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else {
            return
        }

        handleOpenAIEvent(type: type, event: event)
    }

    private func handleOpenAIEvent(type: String, event: [String: Any]) {
        eventsFromOpenAI += 1
        lastOpenAIEventType = type
        switch type {
        case "session.created":
            reconnectAttempts = 0
            sendSessionUpdate()
        case "session.updated":
            statusText = "Live"
            sendToWatch(.ready, payload: [RealtimeMessageKey.voiceEngine: activeVoiceEngine.rawValue])
        case "error":
            let text: String
            if let direct = event["message"] as? String {
                text = direct
            } else if let nested = event["error"] as? [String: Any],
                      let message = nested["message"] as? String {
                text = message
            } else {
                text = "OpenAI realtime error"
            }
            sendErrorToWatch(text)
        case "input_audio_buffer.speech_started":
            sendToWatch(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            sendToWatch(.speechStopped)
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String {
                sendToWatch(.userTranscript, text: transcript)
                appendTranscriptLine(.user, transcript)
            }
        case "response.output_audio.delta", "response.audio.delta":
            if let encoded = event["delta"] as? String,
               let audio = Data(base64Encoded: encoded)
            {
                bufferAssistantAudio(audio)
            }
        case "response.content_part.done":
            flushAssistantAudio()
            if let part = event["part"] as? [String: Any] {
                handleCompletedContentPart(part)
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                sendToWatch(.assistantTranscriptDelta, text: delta)
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            if let transcript = event["transcript"] as? String {
                sendToWatch(.assistantTranscriptFinal, text: transcript)
                appendTranscriptLine(.assistant, transcript)
            }
        case "response.done":
            flushAssistantAudio()
            if !automaticTurnDetectionEnabled {
                sendOpenAIEvent(["type": "input_audio_buffer.clear"])
            }
            sendToWatch(.responseDone)
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any] {
                handleOutputItem(item)
            }
        default:
            break
        }
    }

    private func handleOutputItem(_ item: [String: Any]) {
        guard
            (item["type"] as? String) == "function_call",
            let name = item["name"] as? String,
            let callId = item["call_id"] as? String,
            let argumentsJSON = item["arguments"] as? String
        else {
            return
        }

        guard name == "web_search" else { return }
        Task { [weak self] in
            await self?.runWebSearchCall(callId: callId, argumentsJSON: argumentsJSON)
        }
    }

    private func runWebSearchCall(callId: String, argumentsJSON: String) async {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let query = ((parsed["query"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            await sendWebSearchOutput(callId: callId, payload: [
                "error": true,
                "message": "Missing or invalid query."
            ])
            return
        }

        await MainActor.run {
            webSearchCount += 1
            statusText = "Searching"
            sendToWatch(.connectionStatus, text: "Searching")
        }

        do {
            let answer = try await Self.withTimeout(seconds: 25) { [session = urlSession] in
                try await Self.runResponsesWebSearch(query: query, session: session)
            }
            let isoFormatter = ISO8601DateFormatter()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            let now = Date()
            await sendWebSearchOutput(callId: callId, payload: [
                "query": query,
                "answer": answer,
                "currentDate": dateFormatter.string(from: now),
                "searchedAt": isoFormatter.string(from: now),
                "source": "OpenAI web_search"
            ])
        } catch {
            await sendWebSearchOutput(callId: callId, payload: [
                "error": true,
                "query": query,
                "message": error.localizedDescription
            ])
        }
    }

    private static func runResponsesWebSearch(query: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let todayString = dateFormatter.string(from: Date())

        let instructions = """
        You are a research assistant. Today is \(todayString). Use the web_search tool to answer the user's question with current information from a fresh source. Reply with a concise factual answer in 1-3 short sentences. Include the key number/value if the question asks for one. When the question is about weather, prices, or any other time-bounded value, only state what the source says about today specifically — do not turn a multi-day forecast or weekly summary into a claim about today, and do not hedge with conditions ("possible showers", "could be") unless the source explicitly says they apply today. If today's specific value is not in the search results, say "I couldn't find a current figure for today" instead of guessing. Mention the date or source briefly when useful. Do not invent citations.
        """

        let input = "Today is \(todayString). \(query)"

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": PhoneConfiguration.regularVoiceModel,
            "instructions": instructions,
            "input": input,
            "tools": [["type": "web_search"]],
            "tool_choice": "auto"
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WebSearchError.http(code, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchError.decode
        }

        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            let text = output.compactMap { item -> String? in
                guard let content = item["content"] as? [[String: Any]] else { return nil }
                return content.compactMap { $0["text"] as? String }.joined()
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        throw WebSearchError.decode
    }

    private func sendWebSearchOutput(callId: String, payload: [String: Any]) async {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        await MainActor.run {
            sendOpenAIEvent([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": jsonString
                ]
            ])
            sendOpenAIEvent(["type": "response.create"])
            statusText = "Live"
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WebSearchError.timeout
            }
            guard let value = try await group.next() else {
                throw WebSearchError.timeout
            }
            group.cancelAll()
            return value
        }
    }

    private func handleCompletedContentPart(_ part: [String: Any]) {
        if let encoded = part["audio"] as? String,
           let audio = Data(base64Encoded: encoded)
        {
            sendAudioToWatch(audio)
        }

        if let transcript = part["transcript"] as? String {
            sendToWatch(.assistantTranscriptFinal, text: transcript)
            appendTranscriptLine(.assistant, transcript)
        } else if let text = part["text"] as? String {
            sendToWatch(.assistantTranscriptFinal, text: text)
            appendTranscriptLine(.assistant, text)
        }
    }

    private func sendSessionUpdate() {
        let voice = PhoneConfiguration.realtimeVoice
        let turnDetection: Any = automaticTurnDetectionEnabled
            ? [
                "type": "semantic_vad",
                "eagerness": PhoneConfiguration.realtimeEagerness.rawValue,
                "create_response": true,
                "interrupt_response": true
            ]
            : NSNull()

        var transcriptionConfig: [String: Any] = ["model": "gpt-4o-mini-transcribe"]
        if let iso = PhoneConfiguration.assistantLanguage.iso639Code {
            transcriptionConfig["language"] = iso
        }

        let instructions = PhoneConfiguration.effectiveInstructions
            + " " + Self.realtimeWebSearchInstructions

        let tools: [[String: Any]] = [Self.webSearchToolSpec]

        let session: [String: Any] = [
            "instructions": instructions,
            "modalities": ["text", "audio"],
            "voice": voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "input_audio_transcription": transcriptionConfig,
            "turn_detection": turnDetection,
            "tools": tools,
            "tool_choice": "auto"
        ]

        sendOpenAIEvent([
            "type": "session.update",
            "session": session
        ])
        lastSentVoice = voice
        lastSentLanguage = PhoneConfiguration.assistantLanguage
        lastSentVADEagerness = PhoneConfiguration.realtimeEagerness
    }

    private func applyVoiceChangeIfNeeded() {
        guard webSocket != nil else {
            return
        }
        let voiceChanged = PhoneConfiguration.realtimeVoice != lastSentVoice
        let languageChanged = PhoneConfiguration.assistantLanguage != lastSentLanguage
        let vadChanged = PhoneConfiguration.realtimeEagerness != lastSentVADEagerness
        guard voiceChanged || languageChanged || vadChanged else {
            return
        }
        sendSessionUpdate()
    }

    private static let webSearchToolSpec: [String: Any] = [
        "type": "function",
        "name": "web_search",
        "description": "Look up any current, recent, or time-sensitive information. The phone runs the search and returns a concise factual answer string. Use this for crypto prices, FX rates, stock prices, weather, news, sports scores, election results, schedules, release dates, laws, software versions, person/company status, or whenever the user explicitly asks to search or look something up.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "The web search query. Include the user's important terms and enough context to retrieve fresh, relevant results."
                ],
                "reason": [
                    "type": "string",
                    "description": "Brief reason web search is needed (latest news, current price, recent rumor, explicit user request)."
                ]
            ],
            "required": ["query"]
        ]
    ]

    private static let realtimeWebSearchInstructions = """
    For anything live, current, or time-sensitive — crypto and stock prices, FX rates, weather, news, sports scores, schedules, releases, laws, software versions, etc. — call the web_search tool. The response is an object with a concise factual "answer" string already produced from a real web search; quote or paraphrase that answer directly and do not second-guess it. Skip web_search for timeless or general knowledge. Before a search that may take a few seconds, give a brief preamble like "Let me check." Never invent citations, URLs, dates, or claims that are not in the answer.
    """

    private func sendOpenAIEvent(_ event: [String: Any]) {
        guard let webSocket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        Task {
            try? await webSocket.send(.string(text))
        }
    }

    private func handleWatchAudio(_ data: Data) {
        if activeVoiceEngine == .gpt5 {
            handleRegularWatchAudio(data)
            return
        }

        audioChunksFromWatch += 1
        lastAudioPeak = peakInt16(data)
        sendOpenAIEvent([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
        audioChunksToOpenAI += 1
    }

    private func handleRegularWatchAudio(_ data: Data) {
        guard !regularTurnInProgress else {
            return
        }

        audioChunksFromWatch += 1
        let peak = peakInt16(data)
        lastAudioPeak = peak

        let hasSpeech = peak >= regularSpeechThreshold
        if !regularSpeechActive {
            guard updateRegularSpeechCandidate(with: data, hasSpeech: hasSpeech) else {
                return
            }
        } else {
            regularAudioBuffer.append(data)
        }

        if hasSpeech {
            regularSilentBytes = 0
        } else {
            regularSilentBytes += data.count
        }

        if regularSilentBytes >= regularSilenceBytes {
            if regularAudioBuffer.count >= regularMinimumSpeechBytes {
                finishRegularTurn()
            } else {
                resetRegularSpeechDetection()
            }
        }
    }

    private func resetRegularSpeechDetection() {
        regularAudioBuffer = Data()
        regularPreSpeechBuffer = Data()
        regularSilentBytes = 0
        regularSpeechCandidateBytes = 0
        regularSpeechActive = false
        if !regularTurnInProgress {
            statusText = "Think Mode"
        }
    }

    private func finishRegularTurn() {
        guard regularSpeechActive else {
            return
        }

        regularSpeechActive = false
        regularSilentBytes = 0
        regularSpeechCandidateBytes = 0
        regularPreSpeechBuffer = Data()
        let audio = regularAudioBuffer
        regularAudioBuffer = Data()
        sendToWatch(.speechStopped)

        guard !regularTurnInProgress else {
            return
        }

        regularTurnInProgress = true
        regularTurnTask = Task { [weak self] in
            await self?.processRegularTurn(audio)
        }
    }

    private func processRegularTurn(_ pcmAudio: Data) async {
        guard !pcmAudio.isEmpty else {
            return
        }

        await MainActor.run {
            statusText = "Transcribing"
        }

        do {
            let transcript = try await transcribePCM16(pcmAudio)
            let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTranscript.isEmpty else {
                await MainActor.run {
                    regularTurnInProgress = false
                    statusText = "Think Mode"
                    sendToWatch(.responseDone)
                }
                return
            }

            await MainActor.run {
                eventsFromOpenAI += 1
                sendToWatch(.userTranscript, text: trimmedTranscript)
                appendTranscriptLine(.user, trimmedTranscript)
                statusText = "Thinking"
            }

            let answer = try await createRegularResponse(for: trimmedTranscript)
            let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run {
                eventsFromOpenAI += 1
                sendToWatch(.assistantTranscriptFinal, text: trimmedAnswer)
                appendTranscriptLine(.assistant, trimmedAnswer)
                rememberRegularTurn(user: trimmedTranscript, assistant: trimmedAnswer)
                statusText = "Speaking"
            }

            let speech = try await synthesizeSpeech(trimmedAnswer)
            await sendAudioToWatchInChunks(speech)

            await MainActor.run {
                eventsFromOpenAI += 1
                sendToWatch(.responseDone)
                regularTurnInProgress = false
                regularTurnTask = nil
                statusText = "Think Mode"
            }
        } catch is CancellationError {
            await MainActor.run {
                regularTurnInProgress = false
                regularTurnTask = nil
                statusText = isActive ? "Think Mode" : "Waiting for watch"
            }
        } catch {
            await MainActor.run {
                regularTurnInProgress = false
                regularTurnTask = nil
                if !isCancellationError(error) {
                    sendErrorToWatch("Think Mode failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateRegularSpeechCandidate(with data: Data, hasSpeech: Bool) -> Bool {
        guard hasSpeech else {
            regularSpeechCandidateBytes = 0
            regularPreSpeechBuffer = Data()
            return false
        }

        regularSpeechCandidateBytes += data.count
        regularPreSpeechBuffer.append(data)

        if regularPreSpeechBuffer.count > regularSpeechStartBytes * 2 {
            regularPreSpeechBuffer = regularPreSpeechBuffer.suffixData(regularSpeechStartBytes * 2)
        }

        guard regularSpeechCandidateBytes >= regularSpeechStartBytes else {
            return false
        }

        regularSpeechActive = true
        regularAudioBuffer = regularPreSpeechBuffer
        regularPreSpeechBuffer = Data()
        regularSilentBytes = 0
        regularSpeechCandidateBytes = 0
        sendToWatch(.speechStarted)
        statusText = "Listening"
        return true
    }

    private func rememberRegularTurn(user: String, assistant: String) {
        regularConversationContext.append("User: \(user)")
        regularConversationContext.append("Assistant: \(assistant)")
        if regularConversationContext.count > 12 {
            regularConversationContext = Array(regularConversationContext.suffix(12))
        }
    }

    private func peakInt16(_ data: Data) -> Int16 {
        data.withUnsafeBytes { raw -> Int16 in
            let samples = raw.bindMemory(to: Int16.self)
            var peak: Int16 = 0
            for sample in samples {
                let magnitude = sample == Int16.min ? Int16.max : Swift.abs(sample)
                if magnitude > peak {
                    peak = magnitude
                }
            }
            return peak
        }
    }

    private func sendToWatch(_ type: RealtimeMessageType, text: String? = nil, payload: [String: Any] = [:]) {
        guard let wcSession, wcSession.isReachable else {
            return
        }

        var payload = payload
        if let text {
            payload[RealtimeMessageKey.text] = text
        }

        let message = RealtimeMessage.encode(type, payload: payload)
        wcSession.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    private func sendAudioToWatch(_ data: Data) {
        guard let wcSession, wcSession.isReachable else {
            return
        }
        wcSession.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }

    private func sendAudioToWatchInChunks(_ data: Data) async {
        var offset = 0
        while offset < data.count {
            if Task.isCancelled {
                return
            }

            let end = min(offset + watchAudioChunkBytes, data.count)
            sendAudioToWatch(data.subdata(in: offset..<end))
            offset = end

            if offset < data.count {
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    private func bufferAssistantAudio(_ data: Data) {
        pendingAssistantAudio.append(data)
        if pendingAssistantAudio.count >= pendingAssistantFlushBytes {
            sendAudioToWatch(pendingAssistantAudio)
            pendingAssistantAudio = Data()
        }
    }

    private func flushAssistantAudio() {
        guard !pendingAssistantAudio.isEmpty else {
            return
        }
        sendAudioToWatch(pendingAssistantAudio)
        pendingAssistantAudio = Data()
    }

    private func sendErrorToWatch(_ message: String) {
        sendToWatch(.error, text: message)
        statusText = "Error: \(message)"
    }

    func clearTranscriptSessions() {
        transcriptSessions = []
        activeTranscriptSessionID = nil
        UserDefaults.standard.removeObject(forKey: transcriptStorageKey)
        UserDefaults.standard.removeObject(forKey: legacyTranscriptStorageKey)
    }

    func deleteTranscriptSession(id: UUID) {
        transcriptSessions.removeAll { $0.id == id }
        if activeTranscriptSessionID == id {
            activeTranscriptSessionID = nil
        }
        saveTranscriptSessions()
    }

    private func appendTranscriptLine(_ speaker: PhoneTranscriptLine.Speaker, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let sessionID = ensureActiveTranscriptSession()
        guard let sessionIndex = transcriptSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        if let last = transcriptSessions[sessionIndex].lines.last,
           last.speaker == speaker,
           last.text == trimmed,
           Date().timeIntervalSince(last.date) < 2
        {
            return
        }

        transcriptSessions[sessionIndex].lines.append(PhoneTranscriptLine(speaker: speaker, text: trimmed))
        if transcriptSessions[sessionIndex].lines.count > maxStoredTranscriptLines {
            transcriptSessions[sessionIndex].lines = Array(transcriptSessions[sessionIndex].lines.suffix(maxStoredTranscriptLines))
        }

        if speaker == .user, transcriptSessions[sessionIndex].title.hasSuffix("chat") {
            transcriptSessions[sessionIndex].title = makeTranscriptTitle(from: trimmed)
        }
        saveTranscriptSessions()
    }

    private func startTranscriptSession(engine: VoiceEngine) {
        let title = engine.displayName + " chat"
        let session = PhoneTranscriptSession(engine: engine, title: title)
        transcriptSessions.append(session)
        activeTranscriptSessionID = session.id
        activeSessionStartedAt = session.date
        activeSessionWebSearchStart = webSearchCount
        activeSessionReconnectStart = reconnectCount
        if transcriptSessions.count > maxStoredTranscriptSessions {
            transcriptSessions = Array(transcriptSessions.suffix(maxStoredTranscriptSessions))
        }
        saveTranscriptSessions()
    }

    private func ensureActiveTranscriptSession() -> UUID {
        if let activeTranscriptSessionID,
           transcriptSessions.contains(where: { $0.id == activeTranscriptSessionID })
        {
            return activeTranscriptSessionID
        }

        let session = PhoneTranscriptSession(engine: activeVoiceEngine, title: activeVoiceEngine.displayName + " chat")
        transcriptSessions.append(session)
        activeTranscriptSessionID = session.id
        activeSessionStartedAt = session.date
        activeSessionWebSearchStart = webSearchCount
        activeSessionReconnectStart = reconnectCount
        saveTranscriptSessions()
        return session.id
    }

    private func finalizeActiveTranscriptSession() {
        guard let sessionID = activeTranscriptSessionID,
              let index = transcriptSessions.firstIndex(where: { $0.id == sessionID })
        else {
            return
        }

        let endedAt = Date()
        transcriptSessions[index].endedAt = endedAt
        transcriptSessions[index].usage = PhoneSessionUsage(
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(activeSessionStartedAt))),
            audioChunksFromWatch: audioChunksFromWatch,
            audioChunksToOpenAI: audioChunksToOpenAI,
            eventsFromOpenAI: eventsFromOpenAI,
            webSearchCount: max(0, webSearchCount - activeSessionWebSearchStart),
            reconnectCount: max(0, reconnectCount - activeSessionReconnectStart)
        )
        let lines = transcriptSessions[index].lines
        saveTranscriptSessions()

        guard lines.count >= 2,
              transcriptSessions[index].summary == nil,
              !PhoneConfiguration.openAIAPIKey.isEmpty
        else {
            return
        }

        Task { [weak self] in
            await self?.generateTranscriptMetadata(for: sessionID, lines: lines)
        }
    }

    private func makeTranscriptTitle(from text: String) -> String {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(8)
            .map(String.init)
        var title = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if title.count > 54 {
            title = String(title.prefix(51)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        return title.isEmpty ? "Voice chat" : title
    }

    private func generateTranscriptMetadata(for sessionID: UUID, lines: [PhoneTranscriptLine]) async {
        let transcript = lines.map { line in
            let speaker = line.speaker == .user ? "User" : "Assistant"
            return "\(speaker): \(line.text)"
        }
        .joined(separator: "\n")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4.1-mini",
            "instructions": "Create compact metadata for an Apple Watch voice transcript. Return only JSON with keys title and summary. Title: 3-7 words, natural, no quotes, no trailing period. Summary: one sentence under 24 words.",
            "input": transcript
        ])

        do {
            let (data, response) = try await urlSession.data(for: request)
            try validateHTTPResponse(response, data: data)
            guard let text = try extractResponseText(from: data),
                  let parsed = parseTranscriptMetadata(text)
            else {
                return
            }

            await MainActor.run {
                guard let index = transcriptSessions.firstIndex(where: { $0.id == sessionID }) else {
                    return
                }
                transcriptSessions[index].title = parsed.title
                transcriptSessions[index].summary = parsed.summary
                saveTranscriptSessions()
            }
        } catch {
            print("[WatchGPTPhone] transcript metadata failed: \(error)")
        }
    }

    private func extractResponseText(from data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let outputText = json["output_text"] as? String {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            let parts = output.compactMap { item -> String? in
                guard let content = item["content"] as? [[String: Any]] else {
                    return nil
                }
                return content.compactMap { part in
                    part["text"] as? String
                }.joined()
            }
            let joined = parts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func parseTranscriptMetadata(_ text: String) -> (title: String, summary: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start <= end
        {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }

        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTitle = json["title"] as? String,
              let rawSummary = json["summary"] as? String
        else {
            return nil
        }

        let title = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"."))
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !summary.isEmpty else {
            return nil
        }

        return (String(title.prefix(64)), String(summary.prefix(180)))
    }

    private func loadTranscriptLines() {
        if let data = UserDefaults.standard.data(forKey: transcriptStorageKey),
           let sessions = try? JSONDecoder().decode([PhoneTranscriptSession].self, from: data)
        {
            transcriptSessions = sessions
            return
        }

        if let data = UserDefaults.standard.data(forKey: legacyTranscriptStorageKey),
           let lines = try? JSONDecoder().decode([PhoneTranscriptLine].self, from: data),
           !lines.isEmpty
        {
            transcriptSessions = [
                PhoneTranscriptSession(title: "Imported transcript", lines: lines)
            ]
            saveTranscriptSessions()
        }
    }

    private func saveTranscriptSessions() {
        guard let data = try? JSONEncoder().encode(transcriptSessions) else {
            return
        }

        UserDefaults.standard.set(data, forKey: transcriptStorageKey)
    }

    private func transcribePCM16(_ pcmAudio: Data) async throws -> String {
        let wav = makeWAVData(fromPCM16: pcmAudio)
        let boundary = "WatchGPT-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")

        var body = Data()
        body.appendMultipartField(name: "model", value: PhoneConfiguration.transcriptionModel, boundary: boundary)
        if let iso = PhoneConfiguration.assistantLanguage.iso639Code {
            body.appendMultipartField(name: "language", value: iso, boundary: boundary)
        }
        body.appendMultipartFile(
            name: "file",
            filename: "watchgpt.wav",
            contentType: "audio/wav",
            data: wav,
            boundary: boundary
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        let (data, response) = try await urlSession.upload(for: request, from: body)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else {
            throw PhoneRealtimeBridgeError.invalidResponse
        }

        return text
    }

    private func createRegularResponse(for transcript: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let context = regularConversationContext.suffix(8).joined(separator: "\n")
        let input: String
        if context.isEmpty {
            input = transcript
        } else {
            input = "\(context)\nUser: \(transcript)"
        }

        let instructions = PhoneConfiguration.effectiveInstructions
            + " You have a web_search tool. Use it for current, recent, or time-sensitive information"
            + " (news, prices, releases, scores, weather, software versions, recent events) and whenever"
            + " the user asks you to search, look up, or check online. Skip it for timeless or general"
            + " knowledge. When you do search, mention source names and dates briefly when useful, and"
            + " never invent citations or claims that aren't in the results."

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": PhoneConfiguration.regularVoiceModel,
            "reasoning": [
                "effort": PhoneConfiguration.regularReasoningEffort.rawValue
            ],
            "instructions": instructions,
            "input": input,
            "tools": [["type": "web_search"]],
            "tool_choice": "auto"
        ])

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhoneRealtimeBridgeError.invalidResponse
        }

        if let outputText = json["output_text"] as? String {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            let parts = output.compactMap { item -> String? in
                guard let content = item["content"] as? [[String: Any]] else {
                    return nil
                }
                return content.compactMap { part in
                    part["text"] as? String
                }.joined()
            }
            let joined = parts.joined(separator: "\n")
            if !joined.isEmpty {
                return joined
            }
        }

        throw PhoneRealtimeBridgeError.invalidResponse
    }

    private func synthesizeSpeech(_ text: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": PhoneConfiguration.ttsModel,
            "voice": PhoneConfiguration.ttsVoice,
            "input": text,
            "response_format": "pcm",
            "instructions": "Speak naturally and warmly. Keep the delivery concise and conversational."
        ])

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)
        return data
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PhoneRealtimeBridgeError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let text = error["message"] as? String {
                message = text
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            throw PhoneRealtimeBridgeError.openAI(message)
        }
    }

    private func isCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func makeWAVData(fromPCM16 pcm: Data) -> Data {
        var data = Data()
        let sampleRate: UInt32 = 24_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = UInt32(36 + pcm.count)

        data.appendASCII("RIFF")
        data.appendLittleEndian(chunkSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

private enum PhoneRealtimeBridgeError: LocalizedError {
    case invalidResponse
    case openAI(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenAI returned an unexpected response."
        case .openAI(let message):
            return message
        }
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }

    func suffixData(_ count: Int) -> Data {
        guard self.count > count else {
            return self
        }

        return subdata(in: index(endIndex, offsetBy: -count)..<endIndex)
    }
}

extension PhoneRealtimeBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            if let error {
                self?.statusText = "WC activation failed: \(error.localizedDescription)"
            } else {
                self?.statusText = session.isWatchAppInstalled ? "Waiting for watch" : "Install WatchGPT on your watch"
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            if session.isReachable {
                self?.statusText = self?.isActive == true ? "Live" : "Watch reachable"
            } else {
                self?.statusText = "Watch not reachable"
                self?.stopRealtime()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            guard let self, let type = RealtimeMessage.type(of: message) else {
                return
            }

            switch type {
            case .start:
                let automaticTurnDetection = message[RealtimeMessageKey.automaticTurnDetection] as? Bool ?? true
                self.startSession(engine: PhoneConfiguration.defaultVoiceEngine, automaticTurnDetection: automaticTurnDetection)
            case .stop:
                self.stopRealtime()
            case .commit:
                self.commitUserTurn()
            case .watchAudioLevel:
                if let text = message[RealtimeMessageKey.text] as? String,
                   let value = Float(text)
                {
                    self.lastWatchInputPeak = value
                }
            default:
                break
            }
        }
    }

    private func commitUserTurn() {
        if activeVoiceEngine == .gpt5 {
            finishRegularTurn()
            return
        }

        guard !automaticTurnDetectionEnabled else {
            return
        }

        guard webSocket != nil else {
            handleSocketLost(reason: "commit while socket was down")
            return
        }
        sendOpenAIEvent(["type": "input_audio_buffer.commit"])
        sendOpenAIEvent(["type": "response.create"])
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in
            self?.handleWatchAudio(messageData)
        }
    }
}
