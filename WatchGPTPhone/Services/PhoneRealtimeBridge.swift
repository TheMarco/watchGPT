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

private struct OpenAITokenUsage: Sendable {
    var input = 0
    var cachedInput = 0
    var output = 0
    var reasoning = 0
    var total = 0

    init(json: [String: Any]?) {
        guard let json else { return }
        input = Self.integer(json["input_tokens"])
        output = Self.integer(json["output_tokens"])
        total = Self.integer(json["total_tokens"])

        let inputDetails = (json["input_tokens_details"] as? [String: Any])
            ?? (json["input_token_details"] as? [String: Any])
        let outputDetails = (json["output_tokens_details"] as? [String: Any])
            ?? (json["output_token_details"] as? [String: Any])
        cachedInput = Self.integer(inputDetails?["cached_tokens"])
        reasoning = Self.integer(outputDetails?["reasoning_tokens"])
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0
    }
}

private struct WebSearchResult: Sendable {
    let answer: String
    let usage: OpenAITokenUsage
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
    @Published private(set) var inputTokens = 0
    @Published private(set) var outputTokens = 0
    private var cachedInputTokens = 0
    private var reasoningTokens = 0
    private var totalTokens = 0
    @Published private(set) var lastOpenAIEventType = "none"
    @Published private(set) var lastReconnectMessage: String?
    @Published private(set) var activeEngine: VoiceEngine = .realtime

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config)
    }()
    private let transcriptStore = TranscriptStore()
    private var transcriptStoreReady = false
    private var transcriptLoadTask: Task<Void, Never>?
    private var transcriptSaveTask: Task<Void, Never>?

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 4
    // All outbound socket frames flow through one ordered queue so protocol-
    // sensitive sequences (function_call_output → response.create, commit →
    // response.create, session.update → appends) can't be reordered by the
    // scheduler the way independent detached Tasks could be.
    private var sendContinuation: AsyncStream<String>.Continuation?
    private var sendTask: Task<Void, Never>?
    private var activeTransportSessionID: UUID?
    private var nextWatchControlSequence: UInt64 = 0
    private var nextWatchAudioSequence: UInt64 = 0
    private var lastWatchControlSequence: UInt64?
    private var lastWatchAudioSequence: UInt64?
    private var consecutiveWatchDeliveryFailures = 0
    private var sessionExpiryTask: Task<Void, Never>?
    private var webSearchTasks: [String: Task<Void, Never>] = [:]
    // Debounces a momentary WCSession reachability dip so a flicker doesn't tear
    // down the whole OpenAI session.
    private var reachabilityLossTask: Task<Void, Never>?
    private var wcSession: WCSession?
    private var pendingAssistantAudio = Data()
    private let pendingAssistantFlushBytes = 9_600
    private var lastSentVoice = ""
    private var lastSentLanguage: AssistantLanguage = .auto
    private var lastSentVADEagerness: RealtimeVADEagerness = .low
    private var lastSentTranscriptionModel = ""
    private var automaticTurnDetectionEnabled = true
    private var activeVoiceEngine: VoiceEngine = .realtime
    private var regularAudioBuffer = Data()
    private var regularPreSpeechBuffer = Data()
    private var regularSilentBytes = 0
    private var regularSpeechCandidateBytes = 0
    private var regularSpeechActive = false
    private var regularTurnInProgress = false
    private var regularTurnTask: Task<Void, Never>?
    private var regularPreviousResponseID: String?
    // Set from the watch's mic-sensitivity preset at session start.
    private var regularSpeechThreshold: Int16 = MicSensitivity.default.thinkModeVADThreshold
    private let regularSpeechStartBytes = 9_600
    private let regularSilenceBytes = 52_800
    private let regularMinimumSpeechBytes = 12_000
    private let regularMaximumTurnBytes = Int(24_000 * 2 * PhoneConfiguration.maxThinkTurnDuration)
    private let watchAudioChunkBytes = 9_600
    private let transcriptStorageKey = "WatchGPTPhone.transcriptSessions.v2"
    private let legacyTranscriptStorageKey = "WatchGPTPhone.transcriptLines.v1"
    private let maxStoredTranscriptLines = 400
    private let maxStoredTranscriptSessions = 50
    private var activeTranscriptSessionID: UUID?
    private var activeSessionStartedAt = Date()
    private var activeSessionWebSearchStart = 0
    private var activeSessionReconnectStart = 0
    // Only these keys should re-push a live session.update; observing them
    // directly avoids reacting to every unrelated UserDefaults write (e.g. each
    // transcript save during a call).
    private let observedDefaultsKeys = [
        PhoneConfiguration.realtimeVoiceKey,
        PhoneConfiguration.assistantLanguageKey,
        PhoneConfiguration.realtimeVADEagernessKey,
        PhoneConfiguration.transcriptionModelKey
    ]
    private var isObservingDefaults = false

    override init() {
        wcSession = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        loadTranscriptLines()
    }

    deinit {
        if isObservingDefaults {
            for key in observedDefaultsKeys {
                UserDefaults.standard.removeObserver(self, forKeyPath: key)
            }
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

        if !isObservingDefaults {
            for key in observedDefaultsKeys {
                UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
            }
            isObservingDefaults = true
        }
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [weak self] in
            self?.applyVoiceChangeIfNeeded()
        }
    }

    private func startSession(engine: VoiceEngine, automaticTurnDetection: Bool) {
        activeVoiceEngine = engine
        activeEngine = engine
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
            sendToWatch(.ready, payload: [RealtimeMessageKey.voiceEngine: activeVoiceEngine.rawValue])
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
            inputTokens = 0
            outputTokens = 0
            cachedInputTokens = 0
            reasoningTokens = 0
            totalTokens = 0
            lastOpenAIEventType = "none"
            lastReconnectMessage = nil
        }
        pendingAssistantAudio = Data()

        let apiKey = PhoneConfiguration.openAIAPIKey

        guard !apiKey.isEmpty else {
            failSession("OpenAI API key not configured on iPhone.")
            return
        }

        guard let endpoint = PhoneConfiguration.realtimeEndpointURL else {
            failSession("Invalid realtime endpoint URL.")
            return
        }

        if !isReconnecting {
            startTranscriptSession(engine: .realtime)
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

        let task = urlSession.webSocketTask(with: request)
        webSocket = task
        startSendQueue()
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
            failSession("OpenAI API key not configured on iPhone.")
            return
        }

        audioChunksFromWatch = 0
        audioChunksToOpenAI = 0
        eventsFromOpenAI = 0
        webSearchCount = 0
        reconnectCount = 0
        inputTokens = 0
        outputTokens = 0
        cachedInputTokens = 0
        reasoningTokens = 0
        totalTokens = 0
        lastOpenAIEventType = "none"
        lastReconnectMessage = nil
        regularAudioBuffer = Data()
        regularPreSpeechBuffer = Data()
        regularSilentBytes = 0
        regularSpeechCandidateBytes = 0
        regularSpeechActive = false
        regularTurnInProgress = false
        regularPreviousResponseID = nil
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
        sessionExpiryTask?.cancel()
        sessionExpiryTask = nil
        for task in webSearchTasks.values {
            task.cancel()
        }
        webSearchTasks.removeAll()
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reachabilityLossTask?.cancel()
        reachabilityLossTask = nil
        reconnectAttempts = 0
        stopSendQueue()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        pendingAssistantAudio = Data()
        lastSentVoice = ""
        lastSentLanguage = .auto
        lastSentVADEagerness = .low
        lastSentTranscriptionModel = ""
        regularTurnTask?.cancel()
        regularTurnTask = nil
        regularAudioBuffer = Data()
        regularPreSpeechBuffer = Data()
        regularSilentBytes = 0
        regularSpeechCandidateBytes = 0
        regularSpeechActive = false
        regularTurnInProgress = false
        regularPreviousResponseID = nil
        activeTranscriptSessionID = nil
        activeTransportSessionID = nil
        lastWatchControlSequence = nil
        lastWatchAudioSequence = nil
        nextWatchControlSequence = 0
        nextWatchAudioSequence = 0
        consecutiveWatchDeliveryFailures = 0
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
        stopSendQueue()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        pendingAssistantAudio = Data()
        lastSentVoice = ""
        lastSentLanguage = .auto
        lastSentVADEagerness = .low
        lastSentTranscriptionModel = ""

        guard isActive else { return }

        guard reconnectAttempts < maxReconnectAttempts else {
            failSession("Realtime disconnected after retries: \(reason). Start again, then repeat your last request.")
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
            let info = RealtimeErrorClassifier.parse(event)
            if RealtimeErrorClassifier.isNonFatal(info) {
                // Recoverable conditions (e.g. a racing cancel/commit, "no active
                // response") must not tear down the watch session.
                print("[WatchGPTPhone] non-fatal realtime error: \(info.message)")
                if statusText.hasPrefix("Error") {
                    statusText = "Live"
                }
                return
            }
            failSession(info.message)
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
            if let response = event["response"] as? [String: Any] {
                recordUsage(OpenAITokenUsage(json: response["usage"] as? [String: Any]))
            }
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

        guard name == "web_search", let sessionID = activeTransportSessionID else { return }
        guard webSearchTasks[callId] == nil else { return }

        let task = Task { [weak self] in
            await self?.runWebSearchCall(
                callId: callId,
                argumentsJSON: argumentsJSON,
                sessionID: sessionID
            )
            await MainActor.run {
                self?.webSearchTasks[callId] = nil
            }
        }
        webSearchTasks[callId] = task
    }

    private func runWebSearchCall(callId: String, argumentsJSON: String, sessionID: UUID) async {
        guard activeTransportSessionID == sessionID else { return }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let query = ((parsed["query"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            await sendWebSearchOutput(callId: callId, sessionID: sessionID, payload: [
                "error": true,
                "message": "Missing or invalid query."
            ])
            return
        }

        guard webSearchCount - activeSessionWebSearchStart < PhoneConfiguration.maxRealtimeWebSearchCallsPerSession else {
            await sendWebSearchOutput(callId: callId, sessionID: sessionID, payload: [
                "error": true,
                "message": "This session reached its web-search limit. Start a new session for more searches."
            ])
            return
        }

        await MainActor.run {
            webSearchCount += 1
            statusText = "Searching"
            sendToWatch(.connectionStatus, text: "Searching")
        }

        do {
            let result = try await Self.withTimeout(seconds: 25) { [session = urlSession] in
                try await Self.runResponsesWebSearch(query: query, session: session)
            }
            recordUsage(result.usage)
            let isoFormatter = ISO8601DateFormatter()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            let now = Date()
            await sendWebSearchOutput(callId: callId, sessionID: sessionID, payload: [
                "query": query,
                "answer": result.answer,
                "currentDate": dateFormatter.string(from: now),
                "searchedAt": isoFormatter.string(from: now),
                "source": "OpenAI web_search"
            ])
        } catch {
            await sendWebSearchOutput(callId: callId, sessionID: sessionID, payload: [
                "error": true,
                "query": query,
                "message": error.localizedDescription
            ])
        }
    }

    private static func runResponsesWebSearch(query: String, session: URLSession) async throws -> WebSearchResult {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
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
            "model": ThinkModelOption.luna.rawValue,
            "reasoning": ["effort": ReasoningEffort.low.rawValue],
            "instructions": instructions,
            "input": input,
            "tools": [["type": "web_search"]],
            "tool_choice": "auto",
            "max_output_tokens": PhoneConfiguration.webSearchMaxOutputTokens,
            "max_tool_calls": 1,
            "store": false
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

        guard let text = OpenAIResponseParsing.outputText(from: json) else {
            throw WebSearchError.decode
        }
        return WebSearchResult(
            answer: text,
            usage: OpenAITokenUsage(json: json["usage"] as? [String: Any])
        )
    }

    private func sendWebSearchOutput(callId: String, sessionID: UUID, payload: [String: Any]) async {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        await MainActor.run {
            guard activeTransportSessionID == sessionID else { return }
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

        var transcriptionConfig: [String: Any] = ["model": PhoneConfiguration.transcriptionModel]
        if let iso = PhoneConfiguration.assistantLanguage.iso639Code {
            transcriptionConfig["language"] = iso
        }

        let instructions = PhoneConfiguration.effectiveInstructions
            + " " + Self.realtimeWebSearchInstructions

        let tools: [[String: Any]] = [Self.webSearchToolSpec]

        let audioInput: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": transcriptionConfig,
            "turn_detection": turnDetection
        ]

        let audioOutput: [String: Any] = [
            "voice": voice,
            "format": ["type": "audio/pcm", "rate": 24000]
        ]

        let session: [String: Any] = [
            "type": "realtime",
            "instructions": instructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": audioInput,
                "output": audioOutput
            ],
            "reasoning": ["effort": ReasoningEffort.low.rawValue],
            "max_output_tokens": PhoneConfiguration.realtimeMaxOutputTokens,
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
        lastSentTranscriptionModel = PhoneConfiguration.transcriptionModel
    }

    private func applyVoiceChangeIfNeeded() {
        guard webSocket != nil else {
            return
        }
        let voiceChanged = PhoneConfiguration.realtimeVoice != lastSentVoice
        let languageChanged = PhoneConfiguration.assistantLanguage != lastSentLanguage
        let vadChanged = PhoneConfiguration.realtimeEagerness != lastSentVADEagerness
        let transcriptionChanged = PhoneConfiguration.transcriptionModel != lastSentTranscriptionModel
        guard voiceChanged || languageChanged || vadChanged || transcriptionChanged else {
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

    private func startSendQueue() {
        sendContinuation?.finish()
        sendTask?.cancel()

        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingOldest(PhoneConfiguration.maxSocketQueueDepth)
        )
        sendContinuation = continuation
        sendTask = Task { [weak self] in
            // This Task inherits MainActor isolation from startSendQueue(), so
            // reading webSocket is a synchronous main-actor access; only the
            // socket send actually suspends.
            for await text in stream {
                guard let socket = self?.webSocket else {
                    continue
                }
                do {
                    try await socket.send(.string(text))
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.handleSocketLost(reason: "send failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func stopSendQueue() {
        sendContinuation?.finish()
        sendContinuation = nil
        sendTask?.cancel()
        sendTask = nil
    }

    private func sendOpenAIEvent(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        // Yielding (rather than spawning a Task) preserves call order on the wire.
        guard let sendContinuation else {
            return
        }

        switch sendContinuation.yield(text) {
        case .enqueued:
            break
        case .dropped:
            failSession("Realtime audio could not keep up. Start a new session and try again.")
        case .terminated:
            if isActive, webSocket != nil {
                handleSocketLost(reason: "outbound queue terminated")
            }
        @unknown default:
            failSession("Realtime transport failed unexpectedly.")
        }
    }

    private func handleWatchAudio(_ data: Data) {
        guard let envelope = RealtimeAudioEnvelope(encoded: data),
              envelope.sessionID == activeTransportSessionID,
              lastWatchAudioSequence.map({ envelope.sequence > $0 }) ?? true
        else {
            return
        }
        lastWatchAudioSequence = envelope.sequence
        consecutiveWatchDeliveryFailures = 0

        if activeVoiceEngine == .gpt5 {
            handleRegularWatchAudio(envelope.audio)
            return
        }

        audioChunksFromWatch += 1
        lastAudioPeak = peakInt16(envelope.audio)
        sendOpenAIEvent([
            "type": "input_audio_buffer.append",
            "audio": envelope.audio.base64EncodedString()
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
        } else if regularAudioBuffer.count >= regularMaximumTurnBytes {
            finishRegularTurn()
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

    /// Aborts an in-flight Think Mode turn (transcribe → think → stream speech)
    /// when the user taps to interrupt on the watch. Cancelling the task also
    /// cancels its in-flight URLSession calls.
    private func cancelRegularTurn() {
        guard activeVoiceEngine == .gpt5 else {
            return
        }

        regularTurnTask?.cancel()
        regularTurnTask = nil
        regularTurnInProgress = false
        resetRegularSpeechDetection()
        sendToWatch(.responseDone)
    }

    private func processRegularTurn(_ pcmAudio: Data) async {
        guard !pcmAudio.isEmpty else {
            return
        }

        // These connectionStatus pings double as keep-alive heartbeats so the
        // watch's idle watchdog doesn't end the session during a long turn.
        statusText = "Transcribing"
        sendToWatch(.connectionStatus, text: "Transcribing")

        do {
            let transcript = try await transcribePCM16(pcmAudio)
            let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

            // Transcription models can return stock phrases ("Thank you",
            // "Thanks for watching") on near-silence; don't burn a whole turn on
            // them.
            guard !trimmedTranscript.isEmpty,
                  !ThinkTranscriptFilter.isLikelyHallucination(trimmedTranscript)
            else {
                regularTurnInProgress = false
                regularTurnTask = nil
                statusText = "Think Mode"
                sendToWatch(.responseDone)
                return
            }

            eventsFromOpenAI += 1
            sendToWatch(.userTranscript, text: trimmedTranscript)
            appendTranscriptLine(.user, trimmedTranscript)
            statusText = "Thinking"
            sendToWatch(.connectionStatus, text: "Thinking")

            let answer = try await createRegularResponse(for: trimmedTranscript)
            let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)

            eventsFromOpenAI += 1
            sendToWatch(.assistantTranscriptFinal, text: trimmedAnswer)
            appendTranscriptLine(.assistant, trimmedAnswer)
            statusText = "Speaking"
            sendToWatch(.connectionStatus, text: "Speaking")

            try await streamSpeechToWatch(trimmedAnswer)

            eventsFromOpenAI += 1
            sendToWatch(.responseDone)
            regularTurnInProgress = false
            regularTurnTask = nil
            statusText = "Think Mode"
        } catch is CancellationError {
            regularTurnInProgress = false
            regularTurnTask = nil
            statusText = isActive ? "Think Mode" : "Waiting for watch"
        } catch {
            regularTurnInProgress = false
            regularTurnTask = nil
            if !isCancellationError(error) {
                failSession("Think Mode failed: \(error.localizedDescription)")
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

    private func recordUsage(_ usage: OpenAITokenUsage) {
        inputTokens += usage.input
        cachedInputTokens += usage.cachedInput
        outputTokens += usage.output
        reasoningTokens += usage.reasoning
        totalTokens += usage.total > 0 ? usage.total : usage.input + usage.output
    }

    private func sendToWatch(_ type: RealtimeMessageType, text: String? = nil, payload: [String: Any] = [:]) {
        guard let wcSession,
              wcSession.isReachable,
              let sessionID = activeTransportSessionID
        else {
            return
        }

        var payload = payload
        if let text {
            payload[RealtimeMessageKey.text] = text
        }

        let sequence = nextWatchControlSequence
        nextWatchControlSequence &+= 1
        let message = RealtimeMessage.encode(
            type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload
        )
        wcSession.sendMessage(message, replyHandler: nil) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.activeTransportSessionID == sessionID else { return }
                self.consecutiveWatchDeliveryFailures += 1
                guard type != .error, self.consecutiveWatchDeliveryFailures >= 3 else { return }
                self.stopRealtime()
                self.statusText = "Error: Watch delivery failed: \(error.localizedDescription)"
            }
        }
    }

    private func sendAudioToWatch(_ data: Data) {
        guard !data.isEmpty,
              data.count <= RealtimeAudioEnvelope.maximumPayloadBytes,
              let wcSession,
              wcSession.isReachable,
              let sessionID = activeTransportSessionID
        else {
            return
        }
        let sequence = nextWatchAudioSequence
        nextWatchAudioSequence &+= 1
        let envelope = RealtimeAudioEnvelope(
            sessionID: sessionID,
            sequence: sequence,
            audio: data
        ).encoded()
        wcSession.sendMessageData(envelope, replyHandler: nil) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.activeTransportSessionID == sessionID else { return }
                self.consecutiveWatchDeliveryFailures += 1
                guard self.consecutiveWatchDeliveryFailures >= 3 else { return }
                self.stopRealtime()
                self.statusText = "Error: Watch audio delivery failed: \(error.localizedDescription)"
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

    private func failSession(_ message: String) {
        sendErrorToWatch(message)
        stopRealtime()
        statusText = "Error: \(message)"
    }

    func clearTranscriptSessions() {
        transcriptSessions = []
        activeTranscriptSessionID = nil
        transcriptLoadTask?.cancel()
        transcriptLoadTask = nil
        transcriptSaveTask?.cancel()
        transcriptSaveTask = nil
        transcriptStoreReady = true
        UserDefaults.standard.removeObject(forKey: transcriptStorageKey)
        UserDefaults.standard.removeObject(forKey: legacyTranscriptStorageKey)
        Task { [transcriptStore] in
            do {
                try await transcriptStore.delete()
            } catch {
                print("[WatchGPTPhone] transcript delete failed: \(error)")
            }
        }
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
            reconnectCount: max(0, reconnectCount - activeSessionReconnectStart),
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens
        )
        let lines = transcriptSessions[index].lines
        saveTranscriptSessions()
        flushTranscriptHistory()

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
        request.timeoutInterval = 30
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": PhoneConfiguration.transcriptMetadataModel,
            "reasoning": ["effort": ReasoningEffort.low.rawValue],
            "instructions": "Create compact metadata for an Apple Watch voice transcript. Return only JSON with keys title and summary. Title: 3-7 words, natural, no quotes, no trailing period. Summary: one sentence under 24 words.",
            "input": transcript,
            "max_output_tokens": PhoneConfiguration.metadataMaxOutputTokens,
            "store": false,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "transcript_metadata",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "summary": ["type": "string"]
                        ],
                        "required": ["title", "summary"],
                        "additionalProperties": false
                    ]
                ]
            ]
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
        return OpenAIResponseParsing.outputText(from: json)
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
        let legacySessions: [PhoneTranscriptSession]
        if let data = UserDefaults.standard.data(forKey: transcriptStorageKey),
           let sessions = try? JSONDecoder().decode([PhoneTranscriptSession].self, from: data)
        {
            legacySessions = sessions
        } else if let data = UserDefaults.standard.data(forKey: legacyTranscriptStorageKey),
                  let lines = try? JSONDecoder().decode([PhoneTranscriptLine].self, from: data),
                  !lines.isEmpty
        {
            legacySessions = [PhoneTranscriptSession(title: "Imported transcript", lines: lines)]
        } else {
            legacySessions = []
        }

        transcriptLoadTask = Task { [weak self, transcriptStore] in
            do {
                let loaded = try await transcriptStore.load(legacySessions: legacySessions)
                guard !Task.isCancelled, let self else { return }

                let inMemorySessions = self.transcriptSessions
                let loadedIDs = Set(loaded.map(\.id))
                self.transcriptSessions = loaded + inMemorySessions.filter { !loadedIDs.contains($0.id) }
                self.transcriptStoreReady = true
                self.transcriptLoadTask = nil
                UserDefaults.standard.removeObject(forKey: self.transcriptStorageKey)
                UserDefaults.standard.removeObject(forKey: self.legacyTranscriptStorageKey)

                if !inMemorySessions.isEmpty {
                    self.saveTranscriptSessions()
                }
            } catch {
                guard let self else { return }
                self.transcriptStoreReady = true
                self.transcriptLoadTask = nil
                print("[WatchGPTPhone] transcript load failed: \(error)")
            }
        }
    }

    private func saveTranscriptSessions() {
        guard transcriptStoreReady else {
            return
        }

        let snapshot = transcriptSessions
        transcriptSaveTask?.cancel()
        transcriptSaveTask = Task { [transcriptStore] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            await transcriptStore.save(snapshot)
        }
    }

    func flushTranscriptHistory() {
        guard transcriptStoreReady else { return }
        let pendingSave = transcriptSaveTask
        Task { [transcriptStore] in
            await pendingSave?.value
            do {
                try await transcriptStore.flush()
            } catch {
                print("[WatchGPTPhone] transcript flush failed: \(error)")
            }
        }
    }

    private func transcribePCM16(_ pcmAudio: Data) async throws -> String {
        let wav = PCMWAV.data(fromPCM16: pcmAudio)
        let boundary = "WatchGPT-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
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
        request.timeoutInterval = 75
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let instructions = PhoneConfiguration.effectiveInstructions
            + " You have a web_search tool. Use it for current, recent, or time-sensitive information"
            + " (news, prices, releases, scores, weather, software versions, recent events) and whenever"
            + " the user asks you to search, look up, or check online. Skip it for timeless or general"
            + " knowledge. When you do search, mention source names and dates briefly when useful, and"
            + " never invent citations or claims that aren't in the results."

        var body: [String: Any] = [
            "model": PhoneConfiguration.regularVoiceModel,
            "reasoning": [
                "effort": PhoneConfiguration.regularReasoningEffort.rawValue
            ],
            "instructions": instructions,
            "input": transcript,
            "tools": [["type": "web_search"]],
            "tool_choice": "auto",
            "max_output_tokens": PhoneConfiguration.thinkMaxOutputTokens,
            "max_tool_calls": PhoneConfiguration.maxToolCallsPerThinkTurn,
            "store": true
        ]
        if let regularPreviousResponseID {
            body["previous_response_id"] = regularPreviousResponseID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhoneRealtimeBridgeError.invalidResponse
        }

        if let responseID = json["id"] as? String, !responseID.isEmpty {
            regularPreviousResponseID = responseID
        }
        recordUsage(OpenAITokenUsage(json: json["usage"] as? [String: Any]))

        // Count any server-side searches OpenAI ran so usage metrics reflect Think
        // Mode searches (previously always zero — only Fast Mode incremented it).
        let searches = OpenAIResponseParsing.webSearchCallCount(in: json)
        if searches > 0 {
            webSearchCount += searches
        }

        guard let text = OpenAIResponseParsing.outputText(from: json) else {
            throw PhoneRealtimeBridgeError.invalidResponse
        }
        return text
    }

    // Requests speech from GPT-Audio and forwards its raw PCM16 response to the
    // watch in paced, Int16-aligned chunks. Runs off the main actor (only the
    // per-chunk WCSession send hops back).
    nonisolated private func streamSpeechToWatch(_ text: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(PhoneConfiguration.openAIAPIKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": PhoneConfiguration.ttsModel,
            "modalities": ["text", "audio"],
            "audio": [
                "voice": PhoneConfiguration.ttsVoice,
                "format": "pcm16"
            ],
            "messages": [
                [
                    "role": "developer",
                    "content": "Read the user's answer aloud verbatim. Do not add, omit, summarize, or rephrase any words. Speak naturally and warmly."
                ],
                ["role": "user", "content": text]
            ],
            "store": false
        ])

        let (responseData, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: responseData)
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let audio = message["audio"] as? [String: Any],
              let encodedAudio = audio["data"] as? String,
              let pcm = Data(base64Encoded: encodedAudio),
              !pcm.isEmpty
        else {
            throw PhoneRealtimeBridgeError.invalidResponse
        }

        let chunkBytes = watchAudioChunkBytes
        var offset = 0
        while offset < pcm.count {
            try Task.checkCancellation()
            let remaining = pcm.count - offset
            let length = min(chunkBytes, remaining)
            let alignedLength = length - (length % 2)
            guard alignedLength > 0 else { break }
            await sendAudioToWatch(Data(pcm[offset..<(offset + alignedLength)]))
            offset += alignedLength
            if offset < pcm.count {
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    nonisolated private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
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
        let isWatchAppInstalled = session.isWatchAppInstalled
        Task { @MainActor [weak self] in
            if let error {
                self?.statusText = "WC activation failed: \(error.localizedDescription)"
            } else {
                self?.statusText = isWatchAppInstalled ? "Waiting for watch" : "Install WatchGPT on your watch"
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }

            if isReachable {
                self.reachabilityLossTask?.cancel()
                self.reachabilityLossTask = nil
                self.statusText = self.isActive ? "Live" : "Watch reachable"
                return
            }

            self.statusText = "Watch not reachable"
            guard self.isActive, self.reachabilityLossTask == nil else { return }

            // WCSession.isReachable flickers constantly; only tear the session
            // down if the dip is sustained, mirroring the watch's tolerance.
            self.reachabilityLossTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    self.reachabilityLossTask = nil
                    if self.isActive, self.wcSession?.isReachable == false {
                        self.stopRealtime()
                    }
                }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let snapshot = RealtimeControlMessage(message)
        Task { @MainActor [weak self] in
            guard let self,
                  let type = RealtimeMessage.type(of: snapshot.value),
                  let sessionID = RealtimeMessage.sessionID(of: snapshot.value),
                  let sequence = RealtimeMessage.sequence(of: snapshot.value)
            else {
                return
            }

            if type == .start {
                if self.activeTransportSessionID != sessionID {
                    if self.activeTransportSessionID != nil || self.isActive {
                        self.stopRealtime()
                    }
                    self.activeTransportSessionID = sessionID
                    self.nextWatchControlSequence = 0
                    self.nextWatchAudioSequence = 0
                    self.lastWatchAudioSequence = nil
                    self.consecutiveWatchDeliveryFailures = 0
                    self.scheduleSessionExpiry(for: sessionID)
                } else if let lastSequence = self.lastWatchControlSequence,
                          sequence <= lastSequence
                {
                    return
                }
                self.lastWatchControlSequence = sequence
            } else {
                guard sessionID == self.activeTransportSessionID,
                      self.lastWatchControlSequence.map({ sequence > $0 }) ?? true
                else {
                    return
                }
                self.lastWatchControlSequence = sequence
            }
            self.consecutiveWatchDeliveryFailures = 0

            switch type {
            case .start:
                let automaticTurnDetection = snapshot.value[RealtimeMessageKey.automaticTurnDetection] as? Bool ?? true
                if let rawSensitivity = snapshot.value[RealtimeMessageKey.micSensitivity] as? String,
                   let sensitivity = MicSensitivity(rawValue: rawSensitivity)
                {
                    self.regularSpeechThreshold = sensitivity.thinkModeVADThreshold
                }
                self.startSession(engine: PhoneConfiguration.defaultVoiceEngine, automaticTurnDetection: automaticTurnDetection)
            case .stop:
                self.stopRealtime()
            case .commit:
                self.commitUserTurn()
            case .cancelTurn:
                self.cancelRegularTurn()
            case .watchAudioLevel:
                if let text = snapshot.value[RealtimeMessageKey.text] as? String,
                   let value = Float(text)
                {
                    self.lastWatchInputPeak = value
                }
            default:
                break
            }
        }
    }

    private func scheduleSessionExpiry(for sessionID: UUID) {
        sessionExpiryTask?.cancel()
        sessionExpiryTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(PhoneConfiguration.maxSessionDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.activeTransportSessionID == sessionID else { return }
                self.failSession("The 10-minute session limit was reached. Start a new session to continue.")
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
