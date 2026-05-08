import AVFoundation
import Foundation
import UIKit
import WatchConnectivity

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
    private let pendingAssistantFlushBytes = 19_200
    private var lastSentVoice = ""
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        wcSession = WCSession.isSupported() ? WCSession.default : nil
        super.init()
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

    private func startRealtime() {
        guard webSocket == nil else {
            return
        }

        let isReconnecting = reconnectAttempts > 0
        if !isReconnecting {
            audioChunksFromWatch = 0
            audioChunksToOpenAI = 0
            eventsFromOpenAI = 0
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

        guard isActive else { return }

        guard reconnectAttempts < maxReconnectAttempts else {
            sendErrorToWatch("Realtime disconnected after retries: \(reason). Tap stop, then start.")
            stopRealtime()
            return
        }

        reconnectAttempts += 1
        statusText = "Reconnecting (\(reconnectAttempts)/\(maxReconnectAttempts))…"

        let delay = pow(2.0, Double(reconnectAttempts - 1))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isActive else { return }
                self.startRealtime()
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
        switch type {
        case "session.created":
            reconnectAttempts = 0
            sendSessionUpdate()
        case "session.updated":
            statusText = "Live"
            sendToWatch(.ready)
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
            }
        case "response.done":
            flushAssistantAudio()
            sendOpenAIEvent(["type": "input_audio_buffer.clear"])
            sendToWatch(.responseDone)
        default:
            break
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
        } else if let text = part["text"] as? String {
            sendToWatch(.assistantTranscriptFinal, text: text)
        }
    }

    private func sendSessionUpdate() {
        let voice = PhoneConfiguration.realtimeVoice
        sendOpenAIEvent([
            "type": "session.update",
            "session": [
                "instructions": PhoneConfiguration.realtimeInstructions,
                "modalities": ["text", "audio"],
                "voice": voice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "gpt-4o-mini-transcribe"
                ],
                "turn_detection": NSNull()
            ]
        ])
        lastSentVoice = voice
    }

    private func applyVoiceChangeIfNeeded() {
        guard webSocket != nil else {
            return
        }
        let current = PhoneConfiguration.realtimeVoice
        guard current != lastSentVoice else {
            return
        }
        sendSessionUpdate()
    }

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
        audioChunksFromWatch += 1
        lastAudioPeak = peakInt16(data)
        sendOpenAIEvent([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
        audioChunksToOpenAI += 1
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

    private func sendToWatch(_ type: RealtimeMessageType, text: String? = nil) {
        guard let wcSession, wcSession.isReachable else {
            return
        }

        var payload: [String: Any] = [:]
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
                self.startRealtime()
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
