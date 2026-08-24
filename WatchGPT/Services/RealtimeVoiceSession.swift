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
    @Published private(set) var isCompanionReachable = false
    @Published private(set) var connectionStatusText = "Checking iPhone"
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
    // Upper bound on how long we wait for the assistant before assuming the turn
    // was lost. Generous so Think Mode with high reasoning + web search can run
    // long without the idle watchdog killing the session mid-thought.
    private let maxAssistantWaitSeconds: TimeInterval = 90
    private var awaitingAssistantResponse = false {
        didSet {
            if awaitingAssistantResponse, !oldValue {
                assistantWaitStartedAt = Date()
            } else if !awaitingAssistantResponse {
                assistantWaitStartedAt = nil
            }
        }
    }
    private var assistantWaitStartedAt: Date?
    private var lastAudioLevelSentAt = Date.distantPast
    private var activeSessionID: UUID?
    private var nextControlSequence: UInt64 = 0
    private var nextAudioSequence: UInt64 = 0
    private var lastPhoneControlSequence: UInt64?
    private var lastPhoneAudioSequence: UInt64?
    private var sessionStartedAt: Date?
    private var consecutiveDeliveryFailures = 0
    private let maxSessionDuration: TimeInterval = 10 * 60

    override init() {
        wcSession = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        wcSession?.delegate = self
        wcSession?.activate()
        refreshCompanionState()
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

        refreshCompanionState()
        guard wcSession.isReachable else {
            errorMessage = RealtimeVoiceSessionError.companionUnreachable.localizedDescription
            // A single failure haptic here is safe: no voice session is running,
            // so it can't destabilize one (the documented "no haptics in-session"
            // rule still holds). It tells the user the tap registered.
            WKInterfaceDevice.current().play(.failure)
            return
        }

        phase = .connecting
        activeSessionID = UUID()
        nextControlSequence = 0
        nextAudioSequence = 0
        lastPhoneControlSequence = nil
        lastPhoneAudioSequence = nil
        sessionStartedAt = Date()
        consecutiveDeliveryFailures = 0
        errorMessage = nil
        latestUserTranscript = ""
        latestAssistantTranscript = ""
        assistantDraft = ""
        automaticConversationEnabledForSession = UserDefaults.standard.bool(
            forKey: AppConfiguration.automaticConversationKey,
            default: true
        )
        voiceEngineForSession = .realtime

        runtimeKeeper.start(
            useWorkoutRuntime: UserDefaults.standard.bool(
                forKey: AppConfiguration.workoutRuntimeKey,
                default: true
            )
        )
        audioIO.setInputGain(AppConfiguration.micSensitivity.inputGain)
        audioIO.setOutputVolume(AppConfiguration.outputVolume.gain)
        lastActivityAt = Date()
        lastAudioLevelSentAt = .distantPast
        startWatchdog()
        sendStartToPhone()
    }

    private func noteActivity() {
        lastActivityAt = Date()
    }

    func prewarmAudio() {
        audioIO.setInputGain(AppConfiguration.micSensitivity.inputGain)
        audioIO.setOutputVolume(AppConfiguration.outputVolume.gain)
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
        sendControlToPhone(.stop, reportsFailure: false)

        audioIO.stop()
        runtimeKeeper.stop()
        stopWatchdog()
        hasStartedAudio = false
        playbackEndsAt = .distantPast
        assistantPlaybackStartedAt = .distantPast
        lastInputPeak = 0
        awaitingAssistantResponse = false
        activeSessionID = nil
        sessionStartedAt = nil
        lastPhoneControlSequence = nil
        lastPhoneAudioSequence = nil
        phase = .disconnected
    }

    private func sendStartToPhone() {
        sendControlToPhone(
            .start,
            payload: [
                RealtimeMessageKey.automaticTurnDetection: automaticConversationEnabledForSession,
                RealtimeMessageKey.micSensitivity: AppConfiguration.micSensitivity.rawValue
            ],
            failurePrefix: "Could not reach iPhone",
            reportsFailure: true
        )
    }

    private func sendControlToPhone(
        _ type: RealtimeMessageType,
        payload: [String: Any] = [:],
        failurePrefix: String = "iPhone delivery failed",
        reportsFailure: Bool
    ) {
        guard let wcSession, let sessionID = activeSessionID else {
            return
        }

        let sequence = nextControlSequence
        nextControlSequence &+= 1
        let message = RealtimeMessage.encode(
            type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload
        )
        wcSession.sendMessage(message, replyHandler: nil) { [weak self] error in
            guard reportsFailure else {
                print("[WatchGPT] \(type.rawValue) delivery failed: \(error.localizedDescription)")
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == sessionID else { return }
                self.errorMessage = "\(failurePrefix): \(error.localizedDescription)"
                self.stop()
            }
        }
    }

    func resetTranscript() {
        transcriptLines.removeAll()
        latestUserTranscript = ""
        latestAssistantTranscript = ""
        assistantDraft = ""
    }

    func beginTurn() {
        noteActivity()

        // In Think Mode a tap must also abort any in-flight turn on the phone
        // (transcribe → think → stream speech). Fast Mode's realtime model
        // handles interruption itself, so this is gpt5-only. Harmless no-op when
        // no turn is running.
        if voiceEngineForSession == .gpt5 {
            sendControlToPhone(
                .cancelTurn,
                failurePrefix: "Could not interrupt Think Mode",
                reportsFailure: true
            )
        }

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

        if let sessionStartedAt,
           Date().timeIntervalSince(sessionStartedAt) >= maxSessionDuration
        {
            errorMessage = "The 10-minute session limit was reached. Start a new session to continue."
            stop()
            return
        }

        if let waitingStart = awaitingResponseSince,
           Date().timeIntervalSince(waitingStart) > responseTimeout
        {
            awaitingResponseSince = nil
            errorMessage = "No reply from iPhone. The realtime session may have dropped — tap stop, then start to reconnect."
        }

        // A turn is in flight if the assistant is being awaited (Think Mode
        // transcribe/think/speak, or a Fast Mode web-search round-trip). Don't
        // let the idle watchdog end the session during that window — but cap it
        // so a genuinely lost turn still surfaces an error and frees the timer.
        let awaitingTurn = awaitingAssistantResponse || awaitingResponseSince != nil
        if awaitingAssistantResponse,
           let waitStart = assistantWaitStartedAt,
           Date().timeIntervalSince(waitStart) > maxAssistantWaitSeconds
        {
            awaitingAssistantResponse = false
            errorMessage = "No reply from iPhone — the session may have dropped. Tap stop, then start to reconnect."
        }

        if phase == .listening || phase == .connected {
            if !awaitingTurn, Date().timeIntervalSince(lastActivityAt) > idleTimeoutSeconds {
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
                errorMessage = "Connecting timed out. Tap the main button to retry."
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

        sendControlToPhone(
            .commit,
            failurePrefix: "Commit failed",
            reportsFailure: true
        )
    }

    private func handlePhoneMessage(_ message: [String: Any]) {
        guard let type = RealtimeMessage.type(of: message),
              let sessionID = RealtimeMessage.sessionID(of: message),
              sessionID == activeSessionID,
              let sequence = RealtimeMessage.sequence(of: message),
              lastPhoneControlSequence.map({ sequence > $0 }) ?? true
        else {
            return
        }
        lastPhoneControlSequence = sequence
        consecutiveDeliveryFailures = 0

        switch type {
        case .ready:
            connectionStatusText = "iPhone ready"
            if let engineRaw = message[RealtimeMessageKey.voiceEngine] as? String,
               let engine = VoiceEngine(rawValue: engineRaw)
            {
                voiceEngineForSession = engine
            }
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
        case .connectionStatus:
            // Phone progress heartbeats (e.g. "Transcribing", "Thinking",
            // "Searching") double as keep-alive pings during a long turn.
            noteActivity()
            if let text = message[RealtimeMessageKey.text] as? String {
                connectionStatusText = text
            }
        default:
            break
        }
    }

    private func handlePhoneAudio(_ data: Data) {
        guard let envelope = RealtimeAudioEnvelope(encoded: data),
              envelope.sessionID == activeSessionID,
              lastPhoneAudioSequence.map({ envelope.sequence > $0 }) ?? true
        else {
            return
        }
        lastPhoneAudioSequence = envelope.sequence
        consecutiveDeliveryFailures = 0

        if (!isAutomaticConversationEnabled && phase == .listening) || phase == .disconnected {
            return
        }
        awaitingResponseSince = nil
        playAssistantAudio(envelope.audio, prefersOneShotPlayer: false)
    }

    private func sendInputAudio(_ data: Data, inputPeak: Float) {
        guard hasStartedAudio else {
            return
        }

        lastInputPeak = inputPeak
        if inputPeak >= 0.015 {
            noteActivity()
        }

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
                    default: false
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

        guard let sessionID = activeSessionID else {
            return
        }
        let sequence = nextAudioSequence
        nextAudioSequence &+= 1
        let envelope = RealtimeAudioEnvelope(
            sessionID: sessionID,
            sequence: sequence,
            audio: data
        ).encoded()
        wcSession.sendMessageData(envelope, replyHandler: nil) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == sessionID else { return }
                self.consecutiveDeliveryFailures += 1
                guard self.consecutiveDeliveryFailures >= 3 else { return }
                self.errorMessage = "Audio delivery to iPhone failed: \(error.localizedDescription)"
                self.stop()
            }
        }

        // The mic level only drives a diagnostics readout on the phone, so it
        // doesn't need to ship with every ~0.2 s audio chunk. Throttling it keeps
        // the WCSession control channel from competing with audio delivery.
        let now = Date()
        if now.timeIntervalSince(lastAudioLevelSentAt) >= 0.4 {
            lastAudioLevelSentAt = now
            sendControlToPhone(
                .watchAudioLevel,
                payload: [
                    RealtimeMessageKey.text: String(format: "%.4f", inputPeak)
                ],
                reportsFailure: false
            )
        }
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

        audioIO.playPCM16(audio, prefersOneShotPlayer: prefersOneShotPlayer)
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

    private func refreshCompanionState() {
        guard let wcSession else {
            isCompanionReachable = false
            connectionStatusText = "iPhone companion unavailable"
            return
        }

        isCompanionReachable = wcSession.isReachable
        connectionStatusText = wcSession.isReachable
            ? "iPhone ready"
            : "Open WatchGPT on iPhone"
    }
}

extension RealtimeVoiceSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Task { @MainActor [weak self] in
                self?.errorMessage = "WatchConnectivity activation failed: \(error.localizedDescription)"
            }
        } else {
            Task { @MainActor [weak self] in
                self?.refreshCompanionState()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let snapshot = RealtimeControlMessage(message)
        Task { @MainActor [weak self] in
            self?.handlePhoneMessage(snapshot.value)
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
            self.refreshCompanionState()
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
