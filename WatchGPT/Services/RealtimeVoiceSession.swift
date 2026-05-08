import AVFAudio
import Foundation
import WatchConnectivity
import WatchKit

enum RealtimeVoiceSessionError: LocalizedError {
    case companionUnreachable
    case companionNotPaired
    case disconnected
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .companionUnreachable:
            return "Open WatchGPT on your iPhone — the watch needs the iPhone app running to connect."
        case .companionNotPaired:
            return "WatchGPT iPhone companion app is not installed."
        case .disconnected:
            return "Realtime voice disconnected."
        case .microphoneDenied:
            return "Microphone access denied. Open Settings → Privacy & Security → Microphone on the watch and enable WatchGPT."
        }
    }
}

@MainActor
final class RealtimeVoiceSession: NSObject, ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case listening
        case speaking
    }

    @Published private(set) var phase: Phase = .disconnected {
        didSet {
            if oldValue != phase {
                phaseEnteredAt = Date()
            }
        }
    }
    @Published private(set) var latestUserTranscript = ""
    @Published private(set) var latestAssistantTranscript = ""
    @Published private(set) var transcriptLines: [RealtimeTranscriptLine] = []
    @Published var errorMessage: String?

    private let audioIO = RealtimeAudioIO()
    private let wcSession: WCSession?
    private var hasStartedAudio = false
    private var assistantDraft = ""
    private var playbackEndsAt = Date.distantPast
    private var runtimeSession: WKExtendedRuntimeSession?
    private var watchdogTask: Task<Void, Never>?
    private var phaseEnteredAt = Date()
    private var awaitingResponseSince: Date?
    private let responseTimeout: TimeInterval = 12

    override init() {
        wcSession = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        wcSession?.delegate = self
        wcSession?.activate()
    }

    var statusText: String {
        switch phase {
        case .disconnected:
            return "Ready"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Hold to talk"
        case .listening:
            return "Listening"
        case .speaking:
            return "Replying"
        }
    }

    var isConnected: Bool {
        phase != .disconnected
    }

    func start() {
        guard phase == .disconnected else {
            return
        }

        guard let wcSession else {
            errorMessage = RealtimeVoiceSessionError.companionNotPaired.localizedDescription
            return
        }

        guard wcSession.isReachable else {
            errorMessage = RealtimeVoiceSessionError.companionUnreachable.localizedDescription
            return
        }

        phase = .connecting
        errorMessage = nil
        latestUserTranscript = ""
        latestAssistantTranscript = ""
        assistantDraft = ""

        startRuntimeSession()
        startWatchdog()

        wcSession.sendMessage(
            RealtimeMessage.encode(.start),
            replyHandler: nil,
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = "Could not reach iPhone: \(error.localizedDescription)"
                    self?.stop()
                }
            }
        )
    }

    private func startRuntimeSession() {
        guard runtimeSession == nil else {
            return
        }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session
    }

    private func stopRuntimeSession() {
        runtimeSession?.invalidate()
        runtimeSession = nil
    }

    func stop() {
        wcSession?.sendMessage(
            RealtimeMessage.encode(.stop),
            replyHandler: nil,
            errorHandler: nil
        )

        audioIO.stop()
        stopRuntimeSession()
        stopWatchdog()
        hasStartedAudio = false
        playbackEndsAt = .distantPast
        phase = .disconnected
        WKInterfaceDevice.current().play(.stop)
    }

    func resetTranscript() {
        transcriptLines.removeAll()
        latestUserTranscript = ""
        latestAssistantTranscript = ""
        assistantDraft = ""
    }

    func beginTurn() {
        if phase == .speaking || phase == .connecting {
            recoverToConnected()
        }

        guard phase == .connected else {
            print("[WatchGPT] beginTurn ignored, phase=\(phase)")
            return
        }

        audioIO.stopPlayback()
        audioIO.restartIfNeeded()
        phase = .listening
        WKInterfaceDevice.current().play(.start)
    }

    func recoverToConnected() {
        guard phase != .disconnected else {
            return
        }

        audioIO.stopPlayback()
        playbackEndsAt = .distantPast
        assistantDraft = ""
        phase = .connected
    }


    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.checkForStuckPhase()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func checkForStuckPhase() {
        let elapsed = Date().timeIntervalSince(phaseEnteredAt)

        if let waitingStart = awaitingResponseSince,
           Date().timeIntervalSince(waitingStart) > responseTimeout
        {
            awaitingResponseSince = nil
            errorMessage = "No reply from iPhone. The realtime session may have dropped — tap stop, then start to reconnect."
        }

        switch phase {
        case .speaking:
            if Date() >= playbackEndsAt && elapsed > 6 {
                phase = .connected
            }
        case .connecting:
            if elapsed > 12 {
                errorMessage = "Connecting timed out. Tap the orb to retry."
                stop()
            }
        case .listening:
            if elapsed > 60 {
                phase = .connected
            }
        case .connected, .disconnected:
            break
        }
    }

    func commitTurn() {
        guard phase == .listening else {
            return
        }
        phase = .connected
        WKInterfaceDevice.current().play(.click)
        awaitingResponseSince = Date()

        guard let wcSession else { return }

        wcSession.sendMessage(
            RealtimeMessage.encode(.commit),
            replyHandler: nil,
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = "Commit failed: \(error.localizedDescription)"
                    self?.awaitingResponseSince = nil
                }
            }
        )
    }

    private func handlePhoneMessage(_ message: [String: Any]) {
        guard let type = RealtimeMessage.type(of: message) else {
            return
        }

        switch type {
        case .ready:
            phase = .connected
            startAudioIfNeeded()
        case .speechStarted:
            awaitingResponseSince = nil
        case .speechStopped:
            break
        case .userTranscript:
            awaitingResponseSince = nil
            if let text = message[RealtimeMessageKey.text] as? String {
                latestUserTranscript = text
                appendLine(.user, text)
            }
        case .assistantTranscriptDelta:
            awaitingResponseSince = nil
            if let delta = message[RealtimeMessageKey.text] as? String {
                assistantDraft += delta
                latestAssistantTranscript = assistantDraft
            }
        case .assistantTranscriptFinal:
            awaitingResponseSince = nil
            let final = (message[RealtimeMessageKey.text] as? String) ?? assistantDraft
            latestAssistantTranscript = final
            appendLine(.assistant, final)
            assistantDraft = ""
        case .responseDone:
            awaitingResponseSince = nil
            if hasStartedAudio, Date() >= playbackEndsAt {
                phase = .connected
            }
        case .error:
            if let text = message[RealtimeMessageKey.text] as? String {
                errorMessage = text
            } else {
                errorMessage = RealtimeVoiceSessionError.disconnected.localizedDescription
            }
            WKInterfaceDevice.current().play(.failure)
            stop()
        default:
            break
        }
    }

    private func handlePhoneAudio(_ data: Data) {
        if phase == .listening || phase == .disconnected {
            return
        }
        awaitingResponseSince = nil
        playAssistantAudio(data, prefersOneShotPlayer: false)
    }

    private func sendInputAudio(_ data: Data, inputPeak: Float) {
        guard hasStartedAudio, phase == .listening else {
            return
        }

        guard let wcSession, wcSession.isReachable else {
            return
        }

        wcSession.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        wcSession.sendMessage(
            RealtimeMessage.encode(.watchAudioLevel, payload: [
                RealtimeMessageKey.text: String(format: "%.4f", inputPeak)
            ]),
            replyHandler: nil,
            errorHandler: nil
        )
    }

    private func playAssistantAudio(_ audio: Data, prefersOneShotPlayer: Bool) {
        phase = .speaking
        let trailingPad: TimeInterval = 0.35
        let previousBufferEnd = max(playbackEndsAt.addingTimeInterval(-trailingPad), Date())
        let bufferEnd = previousBufferEnd.addingTimeInterval(estimatedPlaybackDuration(forPCM16: audio))
        playbackEndsAt = bufferEnd.addingTimeInterval(trailingPad)
        markConnectedAfterPlayback()

        if UserDefaults.standard.bool(forKey: AppConfiguration.speakRepliesKey, default: true) {
            audioIO.playPCM16(audio, prefersOneShotPlayer: prefersOneShotPlayer)
        }
    }

    private func markConnectedAfterPlayback() {
        let delay = max(0, playbackEndsAt.timeIntervalSinceNow)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            await MainActor.run {
                guard let self,
                      self.hasStartedAudio,
                      self.phase == .speaking,
                      Date() >= self.playbackEndsAt
                else {
                    return
                }

                self.phase = .connected
            }
        }
    }

    private func estimatedPlaybackDuration(forPCM16 audio: Data) -> TimeInterval {
        let bytesPerSample = MemoryLayout<Int16>.size
        let sampleRate = 24_000.0
        return TimeInterval(audio.count / bytesPerSample) / sampleRate
    }

    private func startAudioIfNeeded() {
        guard !hasStartedAudio else {
            return
        }

        Task { [weak self] in
            let granted = await AVAudioApplication.requestRecordPermission()

            await MainActor.run {
                guard let self else {
                    return
                }

                guard granted else {
                    self.errorMessage = RealtimeVoiceSessionError.microphoneDenied.localizedDescription
                    self.stop()
                    return
                }

                do {
                    try self.audioIO.start { [weak self] data, inputPeak in
                        Task { @MainActor in
                            self?.sendInputAudio(data, inputPeak: inputPeak)
                        }
                    }

                    self.hasStartedAudio = true
                    WKInterfaceDevice.current().play(.start)
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.stop()
                }
            }
        }
    }

    private func appendLine(_ speaker: RealtimeTranscriptLine.Speaker, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return
        }

        transcriptLines.append(RealtimeTranscriptLine(speaker: speaker, text: trimmed))

        if transcriptLines.count > AppConfiguration.maxStoredMessages {
            transcriptLines = Array(transcriptLines.suffix(AppConfiguration.maxStoredMessages))
        }
    }
}

extension RealtimeVoiceSession: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[WatchGPT] runtime session started")
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[WatchGPT] runtime session about to expire")
        Task { @MainActor [weak self] in
            guard let self, self.phase != .disconnected else { return }
            self.runtimeSession = nil
            self.startRuntimeSession()
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let reasonValue = reason.rawValue
        let errorString = error?.localizedDescription ?? "nil"
        Task { @MainActor [weak self] in
            print("[WatchGPT] runtime session invalidated, reason=\(reasonValue), error=\(errorString)")
            guard let self else { return }
            self.runtimeSession = nil
            if self.phase != .disconnected {
                self.startRuntimeSession()
            }
        }
    }
}

extension RealtimeVoiceSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Task { @MainActor [weak self] in
                self?.errorMessage = "WatchConnectivity activation failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.handlePhoneMessage(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in
            self?.handlePhoneAudio(messageData)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            print("[WatchGPT] reachability changed: \(reachable)")
        }
    }
}
