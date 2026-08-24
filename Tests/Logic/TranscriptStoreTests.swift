import XCTest
#if SWIFT_PACKAGE
@testable import WatchGPTCore
#else
@testable import WatchGPTPhone
#endif

final class TranscriptStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = temporaryDirectory.appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path)
        {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRoundTrip() async throws {
        let sessions = [makeSession(title: "Round trip", text: "Hello")]
        let store = TranscriptStore(fileURL: fileURL, debounceNanoseconds: 60_000_000_000)

        await store.save(sessions)
        try await store.flush()

        let reloadedStore = TranscriptStore(fileURL: fileURL)
        let loaded = try await reloadedStore.load()
        XCTAssertEqual(loaded, sessions)
    }

    func testCoalescedSaveFlushesOnlyLatestSnapshot() async throws {
        let first = [makeSession(title: "First", text: "Old")]
        let latest = [makeSession(title: "Latest", text: "New")]
        let store = TranscriptStore(fileURL: fileURL, debounceNanoseconds: 60_000_000_000)

        await store.save(first)
        await store.save(latest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try await store.flush()

        let loaded = try await TranscriptStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded, latest)
    }

    func testDeleteRemovesPersistedAndPendingHistory() async throws {
        let store = TranscriptStore(fileURL: fileURL, debounceNanoseconds: 60_000_000_000)
        await store.save([makeSession(title: "Saved", text: "Saved")])
        try await store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await store.save([makeSession(title: "Pending", text: "Pending")])
        try await store.delete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testCorruptDataLoadsAsEmptyHistory() async throws {
        try Data("{not valid json".utf8).write(to: fileURL)

        let loaded = try await TranscriptStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded, [])
    }

    func testCallerSuppliedLegacySessionsAreMigrated() async throws {
        let legacy = [makeSession(title: "Imported transcript", text: "Legacy")]
        let store = TranscriptStore(fileURL: fileURL)

        let loaded = try await store.load(legacySessions: legacy)

        XCTAssertEqual(loaded, legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let persisted = try await TranscriptStore(fileURL: fileURL).load()
        XCTAssertEqual(persisted, legacy)
    }

    func testFlushSurfacesWriteFailure() async throws {
        let blockingFile = temporaryDirectory.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blockingFile)
        let impossibleURL = blockingFile.appendingPathComponent("sessions.json")
        let store = TranscriptStore(
            fileURL: impossibleURL,
            debounceNanoseconds: 60_000_000_000
        )
        await store.save([makeSession(title: "Cannot save", text: "Failure")])

        do {
            try await store.flush()
            XCTFail("Expected flush to surface the filesystem write failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testLegacyUsageWithoutTokenFieldsStillDecodes() throws {
        let json = """
        {
          "durationSeconds": 12,
          "audioChunksFromWatch": 4,
          "audioChunksToOpenAI": 3,
          "eventsFromOpenAI": 2,
          "webSearchCount": 1,
          "reconnectCount": 0
        }
        """

        let usage = try JSONDecoder().decode(PhoneSessionUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.durationSeconds, 12)
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.totalTokens, 0)
    }

    private func makeSession(title: String, text: String) -> PhoneTranscriptSession {
        PhoneTranscriptSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            engine: .realtime,
            title: title,
            summary: "Summary",
            usage: PhoneSessionUsage(
                durationSeconds: 60,
                audioChunksFromWatch: 2,
                audioChunksToOpenAI: 2,
                eventsFromOpenAI: 4,
                webSearchCount: 1,
                reconnectCount: 0
            ),
            lines: [
                PhoneTranscriptLine(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    date: Date(timeIntervalSince1970: 1_700_000_001),
                    speaker: .user,
                    text: text
                )
            ]
        )
    }
}
