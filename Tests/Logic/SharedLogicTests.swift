import XCTest
#if SWIFT_PACKAGE
@testable import WatchGPTCore
#else
@testable import WatchGPTPhone
#endif

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
        let sessionID = UUID()
        let encoded = RealtimeMessage.encode(.start, sessionID: sessionID, sequence: 42, payload: [
            RealtimeMessageKey.automaticTurnDetection: true,
            RealtimeMessageKey.micSensitivity: MicSensitivity.low.rawValue
        ])

        XCTAssertEqual(RealtimeMessage.type(of: encoded), .start)
        XCTAssertEqual(RealtimeMessage.sessionID(of: encoded), sessionID)
        XCTAssertEqual(RealtimeMessage.sequence(of: encoded), 42)
        XCTAssertEqual(encoded[RealtimeMessageKey.automaticTurnDetection] as? Bool, true)
        XCTAssertEqual(encoded[RealtimeMessageKey.micSensitivity] as? String, "low")
    }

    func testRealtimeMessageUnknownTypeIsNil() {
        XCTAssertNil(RealtimeMessage.type(of: [RealtimeMessageKey.type: "nope"]))
        XCTAssertNil(RealtimeMessage.type(of: [:]))
    }

    func testAudioEnvelopeRoundTripAndValidation() {
        let sessionID = UUID()
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = RealtimeAudioEnvelope(
            sessionID: sessionID,
            sequence: 9,
            audio: audio
        ).encoded()

        XCTAssertEqual(
            RealtimeAudioEnvelope(encoded: encoded),
            RealtimeAudioEnvelope(sessionID: sessionID, sequence: 9, audio: audio)
        )
        XCTAssertNil(RealtimeAudioEnvelope(encoded: Data([0x00, 0x01])))

        var wrongVersion = encoded
        wrongVersion[4] = 99
        XCTAssertNil(RealtimeAudioEnvelope(encoded: wrongVersion))
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
