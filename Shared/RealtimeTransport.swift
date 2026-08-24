import Foundation

/// Session-scoped envelope for WatchConnectivity audio packets.
///
/// Raw PCM previously had no identity, so audio delayed by WatchConnectivity
/// could leak into a newly started session. The compact binary header lets both
/// peers reject stale, duplicate, malformed, or implausibly large packets.
struct RealtimeAudioEnvelope: Equatable, Sendable {
    static let maximumPayloadBytes = 128 * 1_024

    let sessionID: UUID
    let sequence: UInt64
    let audio: Data

    private static let magic: [UInt8] = [0x57, 0x47, 0x50, 0x54] // "WGPT"
    private static let version: UInt8 = 1
    private static let headerByteCount = 4 + 1 + 16 + 8

    func encoded() -> Data {
        precondition(!audio.isEmpty && audio.count <= Self.maximumPayloadBytes)

        var result = Data(Self.magic)
        result.append(Self.version)

        var uuid = sessionID.uuid
        withUnsafeBytes(of: &uuid) { bytes in
            result.append(contentsOf: bytes)
        }

        var littleEndianSequence = sequence.littleEndian
        withUnsafeBytes(of: &littleEndianSequence) { bytes in
            result.append(contentsOf: bytes)
        }

        result.append(audio)
        return result
    }

    init(sessionID: UUID, sequence: UInt64, audio: Data) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.audio = audio
    }

    init?(encoded data: Data) {
        guard data.count > Self.headerByteCount,
              data.count <= Self.headerByteCount + Self.maximumPayloadBytes,
              data.starts(with: Self.magic),
              data[4] == Self.version
        else {
            return nil
        }

        let uuidBytes = Array(data[5..<21])
        let uuid: uuid_t = (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )

        var decodedSequence: UInt64 = 0
        for (offset, byte) in data[21..<29].enumerated() {
            decodedSequence |= UInt64(byte) << UInt64(offset * 8)
        }

        sessionID = UUID(uuid: uuid)
        sequence = decodedSequence
        audio = data.subdata(in: Self.headerByteCount..<data.count)
    }
}
