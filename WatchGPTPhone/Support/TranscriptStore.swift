import Foundation

/// Persists transcript history away from the main actor.
///
/// Calls to `save(_:)` replace the pending snapshot and restart the debounce
/// window. Call `flush()` when the app or scene is about to become inactive so
/// the newest pending snapshot is committed immediately and write failures are
/// surfaced to the caller.
actor TranscriptStore {
    static let defaultFileName = "transcript-sessions.json"
    static let defaultDebounceNanoseconds: UInt64 = 350_000_000

    let fileURL: URL

    private let debounceNanoseconds: UInt64
    private var pendingSessions: [PhoneTranscriptSession]?
    private var debounceTask: Task<Void, Never>?
    private var deferredWriteError: Error?

    init(
        fileURL: URL? = nil,
        debounceNanoseconds: UInt64 = TranscriptStore.defaultDebounceNanoseconds
    ) {
        self.fileURL = fileURL ?? Self.applicationSupportFileURL()
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// Loads the current file. Missing or malformed JSON is treated as an empty
    /// store. If the caller provides legacy sessions, they are migrated only
    /// when no valid current file exists.
    ///
    /// Migration is written before returning, so callers can safely remove
    /// their legacy storage after this method succeeds.
    func load(
        legacySessions: [PhoneTranscriptSession]? = nil
    ) throws -> [PhoneTranscriptSession] {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                return try JSONDecoder().decode([PhoneTranscriptSession].self, from: data)
            } catch is DecodingError {
                return try migrateOrReturnEmpty(legacySessions)
            }
        }

        return try migrateOrReturnEmpty(legacySessions)
    }

    /// Schedules the latest complete transcript snapshot for a coalesced save.
    /// Use `flush()` to force the write and observe any deferred write error.
    func save(_ sessions: [PhoneTranscriptSession]) {
        pendingSessions = sessions
        deferredWriteError = nil
        scheduleDebouncedWrite()
    }

    /// Immediately commits the newest pending snapshot. If an automatic
    /// debounced write failed, this retries it and throws if it still cannot be
    /// persisted.
    func flush() throws {
        debounceTask?.cancel()
        debounceTask = nil

        guard let sessions = pendingSessions else {
            if let deferredWriteError {
                throw deferredWriteError
            }
            return
        }

        do {
            try write(sessions)
            pendingSessions = nil
            deferredWriteError = nil
        } catch {
            deferredWriteError = error
            throw error
        }
    }

    /// Removes persisted and pending transcript history. A missing file is not
    /// an error.
    func delete() throws {
        debounceTask?.cancel()
        debounceTask = nil
        pendingSessions = nil
        deferredWriteError = nil

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private static func applicationSupportFileURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let directoryName = Bundle.main.bundleIdentifier ?? "WatchGPTPhone"

        return applicationSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(defaultFileName, isDirectory: false)
    }

    private func migrateOrReturnEmpty(
        _ legacySessions: [PhoneTranscriptSession]?
    ) throws -> [PhoneTranscriptSession] {
        guard let legacySessions, !legacySessions.isEmpty else {
            return []
        }

        try write(legacySessions)
        return legacySessions
    }

    private func scheduleDebouncedWrite() {
        debounceTask?.cancel()

        let delay = debounceNanoseconds
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.performDebouncedWrite()
        }
    }

    private func performDebouncedWrite() {
        debounceTask = nil
        guard let sessions = pendingSessions else {
            return
        }

        do {
            try write(sessions)
            pendingSessions = nil
            deferredWriteError = nil
        } catch {
            // Keep the snapshot so flush() or a later save can retry it.
            deferredWriteError = error
        }
    }

    private func write(_ sessions: [PhoneTranscriptSession]) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        let protection = FileProtectionType.completeUntilFirstUserAuthentication

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        try fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: directoryURL.path
        )

        let data = try JSONEncoder().encode(sessions)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )

        // Preserve protection even if an existing file was atomically replaced.
        try fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: fileURL.path
        )
    }
}
