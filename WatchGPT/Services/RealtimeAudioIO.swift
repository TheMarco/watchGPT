import AVFoundation
import Foundation

enum RealtimeAudioIOError: LocalizedError {
    case inputFormatUnavailable
    case outputFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .inputFormatUnavailable:
            return "The watch microphone is unavailable."
        case .outputFormatUnavailable:
            return "The watch speaker output is unavailable."
        }
    }
}

final class RealtimeAudioIO {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private let resampleFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private var audioPlayer: AVAudioPlayer?
    private var isStarted = false
    private var isPrepared = false
    private var audioOutBuffer = Data()
    private let audioOutLock = NSLock()
    private let audioOutFlushBytes = 9_600

    // `inputGain`/`outputGain` are written from the main actor but read on the
    // real-time audio render thread, so access is guarded. Each render pass
    // reads the value once into a local to keep per-sample work lock-free.
    private let gainLock = NSLock()
    private var _inputGain: Float = MicSensitivity.default.inputGain
    private var _outputGain: Float = OutputVolume.default.gain

    // AVAudioConverter handles sample-rate + channel conversion with proper
    // anti-alias filtering (the old hand-rolled path used nearest-neighbor
    // decimation, which aliased on the watch's 48 kHz mic).
    private var resampler: AVAudioConverter?
    private var resamplerSourceFormat: AVAudioFormat?

    func setInputGain(_ value: Float) {
        gainLock.lock()
        _inputGain = value
        gainLock.unlock()
    }

    func setOutputVolume(_ gain: Float) {
        gainLock.lock()
        _outputGain = gain
        gainLock.unlock()
    }

    private func currentInputGain() -> Float {
        gainLock.lock()
        defer { gainLock.unlock() }
        return _inputGain
    }

    private func currentOutputGain() -> Float {
        gainLock.lock()
        defer { gainLock.unlock() }
        return _outputGain
    }

    private var interruptionObserver: NSObjectProtocol?

    // Wires the graph and sets the session category without activating it,
    // so the cold-start cost on first main-button tap is paid up front.
    func prepare() {
        if isPrepared || isStarted {
            return
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.mainMixerNode.outputVolume = 1.0
        playerNode.volume = 1.0

        try? engine.inputNode.setVoiceProcessingEnabled(true)
        try? engine.outputNode.setVoiceProcessingEnabled(true)

        engine.prepare()
        isPrepared = true
    }

    func start(onInputAudio: @escaping @Sendable (Data, Float) -> Void) throws {
        if isStarted {
            return
        }

        if !isPrepared {
            prepare()
        }

        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeAudioIOError.inputFormatUnavailable
        }

        audioOutLock.lock()
        audioOutBuffer = Data()
        audioOutLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else {
                return
            }

            let inputPeak = self.peakFloat(buffer)

            guard let chunk = self.convertInputBuffer(buffer) else {
                return
            }

            self.audioOutLock.lock()
            self.audioOutBuffer.append(chunk)
            let toFlush: Data?
            if self.audioOutBuffer.count >= self.audioOutFlushBytes {
                toFlush = self.audioOutBuffer
                self.audioOutBuffer = Data()
            } else {
                toFlush = nil
            }
            self.audioOutLock.unlock()

            if let toFlush {
                onInputAudio(toFlush, inputPeak)
            }
        }

        try engine.start()
        playerNode.play()
        isStarted = true

        registerInterruptionObserver()
    }

    private func registerInterruptionObserver() {
        if interruptionObserver != nil {
            return
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard isStarted,
              let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended
        else {
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)

        if !engine.isRunning {
            try? engine.start()
            playerNode.play()
        }
    }

    func stop() {
        guard isStarted else {
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioPlayer?.stop()
        audioPlayer = nil
        engine.stop()

        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }

        audioOutLock.lock()
        audioOutBuffer = Data()
        audioOutLock.unlock()

        isStarted = false
    }

    var isEngineRunning: Bool {
        engine.isRunning
    }

    func restartIfNeeded() {
        guard isStarted else {
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)

        if !engine.isRunning {
            try? engine.start()
        }

        if !playerNode.isPlaying, engine.isRunning {
            playerNode.play()
        }
    }

    func stopPlayback() {
        playerNode.stop()
        playerNode.reset()
        audioPlayer?.stop()
        audioPlayer = nil

        if engine.isRunning {
            playerNode.play()
        }
    }

    func playPCM16(_ data: Data, prefersOneShotPlayer: Bool = false) {
        guard !data.isEmpty else {
            return
        }

        if prefersOneShotPlayer, playPCM16WithAudioPlayer(data) {
            return
        }

        let bytesPerSample = MemoryLayout<Int16>.size
        let frameCount = AVAudioFrameCount(data.count / bytesPerSample)

        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0]
        else {
            return
        }

        let gain = currentOutputGain()
        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return
            }

            for index in 0..<Int(frameCount) {
                let amplified = Float(source[index]) / Float(Int16.max) * gain
                // Soft limit instead of hard clip so loud TTS saturates smoothly
                // rather than crackling.
                channel[index] = tanhf(amplified)
            }
        }

        if !playerNode.isPlaying, engine.isRunning {
            playerNode.play()
        }

        playerNode.scheduleBuffer(buffer)
    }

    private func playPCM16WithAudioPlayer(_ data: Data) -> Bool {
        do {
            let wav = PCMWAV.data(fromPCM16: data)
            audioPlayer = try AVAudioPlayer(data: wav)
            audioPlayer?.prepareToPlay()
            return audioPlayer?.play() == true
        } catch {
            return false
        }
    }

    private func peakFloat(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else {
            return 0
        }

        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for index in 0..<frames {
            let magnitude = Swift.abs(channel[index])
            if magnitude > peak {
                peak = magnitude
            }
        }
        return peak
    }

    private func convertInputBuffer(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else {
            return nil
        }

        let gain = currentInputGain()

        // Fast path: already 24 kHz mono float — pack directly.
        if buffer.format.sampleRate == resampleFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData?[0]
        {
            return packFloat32ToInt16(channel, frames: Int(buffer.frameLength), gain: gain)
        }

        guard let resampled = resampledBuffer(buffer),
              let channel = resampled.floatChannelData?[0]
        else {
            return nil
        }

        return packFloat32ToInt16(channel, frames: Int(resampled.frameLength), gain: gain)
    }

    private func resampledBuffer(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if resampler == nil || resamplerSourceFormat != input.format {
            resampler = AVAudioConverter(from: input.format, to: resampleFormat)
            resamplerSourceFormat = input.format
        }

        guard let resampler else {
            return nil
        }

        let ratio = resampleFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: resampleFormat, frameCapacity: capacity)
        else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = resampler.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }

        return output
    }

    private func packFloat32ToInt16(_ channel: UnsafePointer<Float>, frames: Int, gain: Float) -> Data {
        var data = Data(count: frames * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                out[i] = limitedInt16(channel[i], gain: gain)
            }
        }
        return data
    }

    private func limitedInt16(_ sample: Float, gain: Float) -> Int16 {
        // tanh keeps the result in (-1, 1) so the Int16 conversion never
        // overflows and clipping saturates smoothly instead of wrapping.
        let limited = tanhf(sample * gain)
        return Int16(limited * Float(Int16.max))
    }
}
