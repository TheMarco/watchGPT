import XCTest
@testable import WatchGPTPhone

final class SharedLogicTests: XCTestCase {
    func testWavHeaderIsWellFormed() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let wav = PCMWAV.data(fromPCM16: pcm)

        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")

        let sampleRate = wav.subdata(in: 24..<28).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        XCTAssertEqual(UInt32(littleEndian: sampleRate), 24_000)
    }

    func testRealtimeMessageRoundTrip() {
        let encoded = RealtimeMessage.encode(.start, payload: [
            RealtimeMessageKey.automaticTurnDetection: true,
            RealtimeMessageKey.micSensitivity: MicSensitivity.low.rawValue
        ])

        XCTAssertEqual(RealtimeMessage.type(of: encoded), .start)
        XCTAssertEqual(encoded[RealtimeMessageKey.automaticTurnDetection] as? Bool, true)
        XCTAssertEqual(encoded[RealtimeMessageKey.micSensitivity] as? String, "low")
    }

    func testRealtimeMessageUnknownTypeIsNil() {
        XCTAssertNil(RealtimeMessage.type(of: [RealtimeMessageKey.type: "nope"]))
        XCTAssertNil(RealtimeMessage.type(of: [:]))
    }

    func testMicSensitivityMapping() {
        XCTAssertEqual(MicSensitivity.high.inputGain, 5.5)
        XCTAssertEqual(MicSensitivity.standard.inputGain, 4.0)
        XCTAssertEqual(MicSensitivity.low.inputGain, 2.5)
        // Higher sensitivity should use a lower digital threshold so quiet speech
        // still trips it; lower sensitivity should require more level.
        XCTAssertLessThan(MicSensitivity.high.thinkModeVADThreshold, MicSensitivity.standard.thinkModeVADThreshold)
        XCTAssertLessThan(MicSensitivity.standard.thinkModeVADThreshold, MicSensitivity.low.thinkModeVADThreshold)
    }

    func testOutputVolumeOrdering() {
        XCTAssertLessThan(OutputVolume.quiet.gain, OutputVolume.normal.gain)
        XCTAssertLessThan(OutputVolume.normal.gain, OutputVolume.loud.gain)
        XCTAssertEqual(OutputVolume.default, .normal)
    }

    func testVoiceEngineDisplayNames() {
        XCTAssertEqual(VoiceEngine.realtime.displayName, "Fast Mode")
        XCTAssertEqual(VoiceEngine.gpt5.displayName, "Think Mode")
        // Persisted raw values must not change.
        XCTAssertEqual(VoiceEngine.realtime.rawValue, "realtime")
        XCTAssertEqual(VoiceEngine.gpt5.rawValue, "gpt5")
    }
}
