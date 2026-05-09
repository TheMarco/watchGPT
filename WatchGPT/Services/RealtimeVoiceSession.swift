import AVFAudio
import Foundation
import HealthKit
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
                // Reset the idle clock when the user becomes the expected actor:
                // they shouldn't be charged for time spent listening to the assistant.
                if oldValue == .speaking {
                    lastActivityAt = Date()
                    awaitingAssistantResponse = false
                }
            }
        }
    }
    @Published private(set) var latestUserTranscript = ""
    @Published private(set) var latestAssistantTranscript = ""
    @Published private(set) var transcriptLines: [RealtimeTranscriptLine] = []
    @Published private(set) var lastInputPeak: Float = 0
    @Published var errorMessage: String?

    private let audioIO = RealtimeAudioIO()
    private let wcSession: WCSession?
    private var hasStartedAudio = false
    private var assistantDraft = ""
    private var playbackEndsAt = Date.distantPast
    private var assistantPlaybackStartedAt = Date.distantPast
    private let runtimeKeeper = WatchRuntimeKeeper()
    private var watchdogTask: Task<Void, Never>?
    private var phaseEnteredAt = Date()
    private var awaitingResponseSince: Date?
    private var automaticConversationEnabledForSession = true
    private var voiceEngineForSession: VoiceEngine = .realtime
    private let responseTimeout: TimeInterval = 12
    private var lastActivityAt = Date()
    private let idleTimeoutSeconds: TimeInterval = 30
    private var awaitingAssistantResponse = false

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
            if voiceEngineForSession == .gpt5 {
                return isAutomaticConversationEnabled ? "Think Mode ready" : "Think Mode hold"
            }
            return isAutomaticConversationEnabled ? "Ready to chat" : "Hold to talk"
        case .listening:
            return "Listening"
        case .speaking:
            return "Replying"
        }
    }

    var isConnected: Bool {
        phase != .disconnected
    }

    var isAutomaticConversationEnabled: Bool {
        if phase == .disconnected {
            return UserDefaults.standard.bool(forKey: AppConfiguration.automaticConversationKey, default: true)
        }

        return automaticConversationEnabledForSession
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
        automaticConversationEnabledForSession = UserDefaults.standard.bool(
            forKey: AppConfiguration.automaticConversationKey,
            default: true
        )
        let engineValue = UserDefaults.standard.string(forKey: AppConfiguration.voiceEngineKey) ?? VoiceEngine.realtime.rawValue
        voiceEngineForSession = VoiceEngine(rawValue: engineValue) ?? .realtime

        runtimeKeeper.start(
            useWorkoutRuntime: UserDefaults.standard.bool(
                forKey: AppConfiguration.workoutRuntimeKey,
                default: true
            )
        )
        audioIO.setInputGain(AppConfiguration.micSensitivity.inputGain)
        lastActivityAt = Date()
        startWatchdog()
        sendStartToPhone()
    }

    private func noteActivity() {
        lastActivityAt = Date()
    }

    func prewarmAudio() {
        audioIO.setInputGain(AppConfiguration.micSensitivity.inputGain)
        audioIO.prepare()
    }

    // Wrist-raise / scene reactivation can leave SwiftUI showing a stale
    // frame and the audio engine briefly stopped; nudge both back to life.
    func handleSceneReactivated() {
        guard phase != .disconnected else {
            return
        }

        audioIO.restartIfNeeded()
        objectWillChange.send()
    }

    func stop() {
        wcSession?.sendMessage(
            RealtimeMessage.encode(.stop),
            replyHandler: nil,
            errorHandler: nil
        )

        audioIO.stop()
        runtimeKeeper.stop()
        stopWatchdog()
        hasStartedAudio = false
        playbackEndsAt = .distantPast
        assistantPlaybackStartedAt = .distantPast
        lastInputPeak = 0
        awaitingAssistantResponse = false
        phase = .disconnected
    }

    private func sendStartToPhone() {
        wcSession?.sendMessage(
            RealtimeMessage.encode(.start, payload: [
                RealtimeMessageKey.automaticTurnDetection: automaticConversationEnabledForSession,
                RealtimeMessageKey.voiceEngine: voiceEngineForSession.rawValue
            ]),
            replyHandler: nil,
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = "Could not reach iPhone: \(error.localizedDescription)"
                    self?.stop()
                }
            }
        )
    }

    func resetTranscript() {
        transcriptLines.removeAll()
        latestUserTranscript = ""
        latestAssistantTranscript = ""
        assistantDraft = ""
    }

    func beginTurn() {
        noteActivity()

        if isAutomaticConversationEnabled {
            recoverToConnected()
            phase = .listening
            return
        }

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
    }

    func recoverToConnected() {
        guard phase != .disconnected else {
            return
        }

        audioIO.stopPlayback()
        playbackEndsAt = .distantPast
        assistantDraft = ""
        awaitingAssistantResponse = false
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

        if phase == .listening || phase == .connected {
            if Date().timeIntervalSince(lastActivityAt) > idleTimeoutSeconds {
                stop()
                return
            }
        }

        switch phase {
        case .speaking:
            if Date() >= playbackEndsAt && elapsed > 6 {
                phase = isAutomaticConversationEnabled ? .listening : .connected
            }
        case .connecting:
            if elapsed > 12 {
                errorMessage = "Connecting timed out. Tap the orb to retry."
                stop()
            }
        case .listening:
            if !isAutomaticConversationEnabled && elapsed > 60 {
                phase = .connected
            }
        case .connected, .disconnected:
            break
        }
    }

    func commitTurn() {
        guard !isAutomaticConversationEnabled else {
            return
        }

        guard phase == .listening else {
            return
        }
        noteActivity()
        phase = .connected
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
            if hasStartedAudio, isAutomaticConversationEnabled {
                phase = .listening
            } else {
                phase = .connected
                startAudioIfNeeded()
            }
        case .speechStarted:
            awaitingResponseSince = nil
            awaitingAssistantResponse = false
            noteActivity()
            if isAutomaticConversationEnabled {
                if isInPlaybackEchoWindow() {
                    return
                }
                audioIO.stopPlayback()
                playbackEndsAt = .distantPast
                phase = .listening
            }
        case .speechStopped:
            noteActivity()
            if isAutomaticConversationEnabled {
                awaitingAssistantResponse = true
            }
        case .userTranscript:
            awaitingResponseSince = nil
            noteActivity()
            if let text = message[RealtimeMessageKey.text] as? String {
                latestUserTranscript = text
                appendLine(.user, text)
            }
        case .assistantTranscriptDelta:
            awaitingResponseSince = nil
            noteActivity()
            if let delta = message[RealtimeMessageKey.text] as? String {
                assistantDraft += delta
                latestAssistantTranscript = assistantDraft
            }
        case .assistantTranscriptFinal:
            awaitingResponseSince = nil
            noteActivity()
            let final = (message[RealtimeMessageKey.text] as? String) ?? assistantDraft
            latestAssistantTranscript = final
            appendLine(.assistant, final)
            assistantDraft = ""
        case .responseDone:
            awaitingResponseSince = nil
            noteActivity()
            if hasStartedAudio, Date() >= playbackEndsAt {
                phase = isAutomaticConversationEnabled ? .listening : .connected
            }
        case .error:
            if let text = message[RealtimeMessageKey.text] as? String {
                errorMessage = text
            } else {
                errorMessage = RealtimeVoiceSessionError.disconnected.localizedDescription
            }
            stop()
        default:
            break
        }
    }

    private func handlePhoneAudio(_ data: Data) {
        if (!isAutomaticConversationEnabled && phase == .listening) || phase == .disconnected {
            return
        }
        awaitingResponseSince = nil
        playAssistantAudio(data, prefersOneShotPlayer: false)
    }

    private func sendInputAudio(_ data: Data, inputPeak: Float) {
        guard hasStartedAudio else {
            return
        }

        lastInputPeak = inputPeak

        if isAutomaticConversationEnabled {
            if voiceEngineForSession == .gpt5, phase == .speaking {
                return
            }

            guard phase != .disconnected, phase != .connecting else {
                return
            }

            // Suppress mic during early assistant playback so OpenAI's semantic VAD
            // doesn't see speaker echo (AEC unconverged on turn 1) and fire
            // interrupt_response. With barge-in off, suppress through the entire
            // wait-for-assistant window (speech_stopped → response done) so a
            // breath or background noise during the "thinking" gap can't trigger
            // interrupt_response either. Tap-to-interrupt clears both guards.
            if voiceEngineForSession == .realtime {
                let bargeInEnabled = UserDefaults.standard.bool(
                    forKey: AppConfiguration.voiceBargeInKey,
                    default: true
                )
                if bargeInEnabled {
                    if isInPlaybackEchoWindow() {
                        return
                    }
                } else {
                    if phase == .speaking || awaitingAssistantResponse {
                        return
                    }
                }
            }
        } else {
            guard phase == .listening else {
                return
            }
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
        if phase != .speaking {
            assistantPlaybackStartedAt = Date()
        }
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

    private func isInPlaybackEchoWindow() -> Bool {
        guard phase == .speaking else {
            return false
        }

        let playbackAge = Date().timeIntervalSince(assistantPlaybackStartedAt)
        return playbackAge < 1.25 && Date() < playbackEndsAt
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

                self.phase = self.isAutomaticConversationEnabled ? .listening : .connected
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
                    if self.isAutomaticConversationEnabled, self.phase == .connected {
                        self.phase = .listening
                    }
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

@MainActor
private final class WatchRuntimeKeeper: NSObject {
    private var healthStore: HKHealthStore?
    private var runtimeSession: WKExtendedRuntimeSession?
    private var workoutSession: HKWorkoutSession?
    private var isActive = false
    private var isRequestingWorkoutAuthorization = false

    func start(useWorkoutRuntime: Bool) {
        guard !isActive else {
            return
        }

        isActive = true
        startExtendedRuntimeSession()
        if useWorkoutRuntime {
            startWorkoutRuntime()
        }
    }

    func stop() {
        isActive = false
        isRequestingWorkoutAuthorization = false

        runtimeSession?.invalidate()
        runtimeSession = nil

        workoutSession?.end()
        workoutSession = nil
    }

    private func startExtendedRuntimeSession() {
        guard runtimeSession == nil else {
            return
        }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session
    }

    private func startWorkoutRuntime() {
        guard HKHealthStore.isHealthDataAvailable(),
              workoutSession == nil,
              !isRequestingWorkoutAuthorization
        else {
            print("[WatchGPT] workout runtime skipped")
            return
        }

        let store = healthStore ?? HKHealthStore()
        healthStore = store
        isRequestingWorkoutAuthorization = true

        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.isRequestingWorkoutAuthorization = false

                guard self.isActive else {
                    return
                }

                guard success, error == nil else {
                    let errorText = error?.localizedDescription ?? "authorization not granted"
                    print("[WatchGPT] workout runtime unavailable: \(errorText)")
                    return
                }

                self.createWorkoutSession(with: store)
            }
        }
    }

    private func createWorkoutSession(with store: HKHealthStore) {
        guard workoutSession == nil else {
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            session.delegate = self
            workoutSession = session
            session.startActivity(with: Date())
            print("[WatchGPT] workout runtime started")
        } catch {
            print("[WatchGPT] workout runtime failed: \(error.localizedDescription)")
        }
    }
}

extension WatchRuntimeKeeper: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[WatchGPT] extended runtime session started")
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[WatchGPT] extended runtime session about to expire")
        Task { @MainActor [weak self] in
            guard let self, self.isActive else {
                return
            }

            self.runtimeSession = nil
            self.startExtendedRuntimeSession()
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
            print("[WatchGPT] extended runtime invalidated, reason=\(reasonValue), error=\(errorString)")
            guard let self else {
                return
            }

            self.runtimeSession = nil
            if self.isActive {
                self.startExtendedRuntimeSession()
            }
        }
    }
}

extension WatchRuntimeKeeper: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            print("[WatchGPT] workout runtime state \(fromState.rawValue) -> \(toState.rawValue)")
            guard let self, self.isActive, toState == .ended else {
                return
            }

            self.workoutSession = nil
            self.startWorkoutRuntime()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            print("[WatchGPT] workout runtime failed: \(error.localizedDescription)")
            guard let self, self.isActive else {
                return
            }

            self.workoutSession = nil
            self.startWorkoutRuntime()
        }
    }
}
