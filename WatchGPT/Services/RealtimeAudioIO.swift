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
    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private let playbackFormat = AVAudioFormat(
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
    private let inputGain: Float = 4.0
    private let outputGain: Float = 2.0
    private var interruptionObserver: NSObjectProtocol?

    // Wires the graph and sets the session category without activating it,
    // so the cold-start cost on first orb tap is paid up front.
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

        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return
            }

            for index in 0..<Int(frameCount) {
                let amplified = Float(source[index]) / Float(Int16.max) * outputGain
                channel[index] = max(-1.0, min(1.0, amplified))
            }
        }

        if !playerNode.isPlaying, engine.isRunning {
            playerNode.play()
        }

        playerNode.scheduleBuffer(buffer)
    }

    private func playPCM16WithAudioPlayer(_ data: Data) -> Bool {
        do {
            let wav = makeWAVData(fromPCM16: data)
            audioPlayer = try AVAudioPlayer(data: wav)
            audioPlayer?.prepareToPlay()
            return audioPlayer?.play() == true
        } catch {
            return false
        }
    }

    private func makeWAVData(fromPCM16 pcm: Data) -> Data {
        var data = Data()
        let sampleRate: UInt32 = 24_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = UInt32(36 + pcm.count)
        let subchunk2Size = UInt32(pcm.count)

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
        data.appendLittleEndian(subchunk2Size)
        data.append(pcm)

        return data
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
        guard let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        let inputFrames = Int(buffer.frameLength)
        let inputRate = buffer.format.sampleRate
        let outputRate = wireFormat.sampleRate

        guard inputFrames > 0, inputRate > 0 else {
            return nil
        }

        if inputRate == outputRate {
            return packFloat32ToInt16(channel, frames: inputFrames)
        }

        if inputRate > outputRate {
            let ratio = inputRate / outputRate
            let outputFrames = Int(Double(inputFrames) / ratio)
            var data = Data(count: outputFrames * 2)
            data.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for i in 0..<outputFrames {
                    let srcIdx = Int(Double(i) * ratio)
                    let safeIdx = min(srcIdx, inputFrames - 1)
                    out[i] = floatToInt16(channel[safeIdx])
                }
            }
            return data
        }

        let ratio = outputRate / inputRate
        let outputFrames = Int(Double(inputFrames) * ratio)
        var data = Data(count: outputFrames * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<outputFrames {
                let srcIdx = Double(i) / ratio
                let lower = Int(srcIdx.rounded(.down))
                let upper = min(lower + 1, inputFrames - 1)
                let frac = Float(srcIdx - Double(lower))
                let blended = (1 - frac) * channel[lower] + frac * channel[upper]
                out[i] = floatToInt16(blended)
            }
        }
        return data
    }

    private func packFloat32ToInt16(_ channel: UnsafePointer<Float>, frames: Int) -> Data {
        var data = Data(count: frames * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                out[i] = floatToInt16(channel[i])
            }
        }
        return data
    }

    private func floatToInt16(_ sample: Float) -> Int16 {
        let amplified = sample * inputGain
        let clipped = max(-1.0, min(1.0, amplified))
        return Int16(clipped * Float(Int16.max))
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
}
