import Foundation

// Shared audio helpers used by both the watch and iPhone targets.
//
// Previously the WAV builder and the `Data` little-endian/ASCII helpers were
// copy-pasted into both `RealtimeAudioIO` (watch) and `PhoneRealtimeBridge`
// (phone). They now live here so there is a single implementation.

enum PCMWAV {
    /// Wraps raw little-endian PCM16 mono samples in a minimal WAV container.
    static func data(fromPCM16 pcm: Data, sampleRate: UInt32 = 24_000) -> Data {
        var data = Data()
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

extension Data {
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

/// Microphone capture sensitivity preset. Lives in `Shared` so the phone can
/// derive a matching Think Mode VAD threshold from the watch's chosen preset.
enum MicSensitivity: String, CaseIterable, Identifiable {
    case high
    case standard
    case low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return "High (quiet rooms)"
        case .standard: return "Standard"
        case .low: return "Low (noisy rooms)"
        }
    }

    /// Pre-amp applied to mic samples on the watch before they are sent.
    var inputGain: Float {
        switch self {
        case .high: return 5.5
        case .standard: return 4.0
        case .low: return 2.5
        }
    }

    /// Post-gain Int16 peak the phone's Think Mode local VAD treats as speech.
    /// Because higher sensitivity also amplifies the noise floor, the threshold
    /// is raised slightly for High and lowered for Low so the preset's intent
    /// (High = catch quiet speech, Low = ignore room noise) holds in practice.
    var thinkModeVADThreshold: Int16 {
        switch self {
        case .high: return 1_100
        case .standard: return 1_400
        case .low: return 2_200
        }
    }

    static let `default`: MicSensitivity = .standard
}

/// Playback loudness preset for assistant audio on the watch. Replaces the
/// previously hardcoded 2.0 output gain and pairs with a soft limiter so loud
/// TTS no longer hard-clips.
enum OutputVolume: String, CaseIterable, Identifiable {
    case quiet
    case normal
    case loud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .normal: return "Normal"
        case .loud: return "Loud"
        }
    }

    var gain: Float {
        switch self {
        case .quiet: return 1.3
        case .normal: return 2.0
        case .loud: return 3.2
        }
    }

    static let `default`: OutputVolume = .normal
}
