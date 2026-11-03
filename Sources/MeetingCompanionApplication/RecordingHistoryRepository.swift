import Foundation
import Darwin
import MeetingCompanionCore

/// Result of an operation with non-fatal persistence warning
public struct HistoryPersistenceResult<T: Sendable>: Sendable {
    public let value: T
    public let persistenceWarning: String?

    public init(value: T, persistenceWarning: String? = nil) {
        self.value = value
        self.persistenceWarning = persistenceWarning
    }
}

/// Authoritative application service handling history persistence, disk scanning,
/// and short recording cleanup off MainActor.
/// Preserves audio/transcripts if metadata write fails, merges unknown JSON fields,
/// tracks revisions to prevent scan overwrite races, and applies strict containment/trash safeguards.
public final class RecordingHistoryRepository: @unchecked Sendable {
    private let lock = NSLock()
    private var entriesMap: [URL: RecordingEntry] = [:]
    private var revisions: [URL: Int] = [:]
    private var generation: Int = 0
    private var lastError: String?
    private var unsavedEntries: Set<URL> = []
    private let fileManager = FileManager.default
    private var subscribers: [@Sendable ([RecordingEntry]) -> Void] = []

    public struct Snapshot: Sendable {
        public let revision: Int
        public let entries: [RecordingEntry]
    }
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    private func lockedSnapshot() -> Snapshot {
        Snapshot(revision: revisions.values.reduce(0, +), entries: entriesMap.values.sorted { $0.date > $1.date })
    }

    public func snapshot() -> Snapshot { withLock { lockedSnapshot() } }

    public func observeSnapshots() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream()
        withLock {
            observers[id] = continuation
            continuation.yield(lockedSnapshot())
        }
        continuation.onTermination = { [weak self] _ in
            self?.withLock { self?.observers.removeValue(forKey: id) }
        }
        return stream
    }

    public init() {}

    @discardableResult
    private func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    /// Canonicalizes a recording URL.
    public func canonicalURL(_ url: URL) -> URL {
        RecordingEntry.canonicalURL(url)
    }

    /// Registers a subscriber for entry list updates and immediately delivers the current state.
    @discardableResult
    public func addSubscriber(_ subscriber: @escaping @Sendable ([RecordingEntry]) -> Void) -> [RecordingEntry] {
        let current = withLock {
            subscribers.append(subscriber)
            return entriesMap.values.sorted { $0.date > $1.date }
        }
        return current
    }

    private func notifySubscribers() {
        let (snapshot, currentSubscribers, continuations) = withLock {
            (lockedSnapshot(), subscribers, Array(observers.values))
        }
        for subscriber in currentSubscribers { subscriber(snapshot.entries) }
        for continuation in continuations { continuation.yield(snapshot) }
    }

    /// Returns all current entries sorted by date descending.
    public func allEntries() -> [RecordingEntry] {
        withLock {
            entriesMap.values.sorted { $0.date > $1.date }
        }
    }

    private func lockedEntry(_ url: URL) -> RecordingEntry? {
        let canonical = canonicalURL(url)
        if let cached = entriesMap[canonical] {
            return cached
        }
        if fileManager.fileExists(atPath: canonical.path) {
            let loaded = RecordingEntry.load(recording: canonical)
            entriesMap[canonical] = loaded
            return loaded
        }
        return nil
    }

    /// Internal put implementation. Caller MUST hold lock.
    private func lockedPutThrowing(_ entry: RecordingEntry, persist: Bool = true) throws -> RecordingEntry {
        let canonical = canonicalURL(entry.recording)
        var updatedEntry = entry
        if updatedEntry.recording != canonical {
            updatedEntry = RecordingEntry(recording: canonical, date: entry.date, title: entry.title, phase: entry.phase)
            updatedEntry.duration = entry.duration
            updatedEntry.problems = entry.problems
            updatedEntry.meeting = entry.meeting
            updatedEntry.log = entry.log
        }

        if persist {
            try RecordingPaths.requireStandardLayout(canonical)
            updatedEntry.assessCapabilities()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedData = try encoder.encode(updatedEntry)
            let finalData: Data

            // Validate full metadata path including dangling raw/ symlink
            _ = try TranscriptResultStorage(recordingURL: updatedEntry.recording).metadataData()

            var status = stat()
            if lstat(updatedEntry.metadata.path, &status) == 0 {
                let existingData = try Data(contentsOf: updatedEntry.metadata)
                finalData = try TranscriptResultStorage.mergeUnknownFields(from: existingData, into: encodedData)
            } else {
                let failure = errno
                guard failure == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
                finalData = encodedData
            }

            try finalData.write(to: updatedEntry.metadata, options: .atomic)
            unsavedEntries.remove(canonical)
            updatedEntry.persistenceWarning = nil
        }

        revisions[canonical, default: 0] += 1
        entriesMap[canonical] = updatedEntry
        return updatedEntry
    }

    /// Retrieves an entry by URL if present in cache, otherwise tries loading from disk.
    public func entry(_ url: URL) -> RecordingEntry? {
        withLock {
            lockedEntry(url)
        }
    }

    /// Stores an entry atomically with unknown JSON fields preservation.
    @discardableResult
    public func putThrowing(_ entry: RecordingEntry, persist: Bool = true) throws -> RecordingEntry {
        let (savedEntry, shouldNotify) = try withLock {
            let saved = try lockedPutThrowing(entry, persist: persist)
            return (saved, true)
        }
        if shouldNotify {
            notifySubscribers()
        }
        return savedEntry
    }

    /// Safe version of put that records persistence warning on error without throwing or losing memory state.
    @discardableResult
    public func put(_ entry: RecordingEntry, persist: Bool = true) -> HistoryPersistenceResult<RecordingEntry> {
        let result = withLock {
            do {
                return HistoryPersistenceResult(value: try lockedPutThrowing(entry, persist: persist))
            } catch {
                let warning = "Не удалось сохранить историю. Аудио не удалено: " + error.localizedDescription
                if !RecordingPaths.isStandardLayout(entry.recording) {
                    return HistoryPersistenceResult(value: entriesMap[canonicalURL(entry.recording)] ?? RecordingEntry.load(recording: entry.recording), persistenceWarning: warning)
                }
                return HistoryPersistenceResult(value: retainUnsaved(entry, warning: warning), persistenceWarning: warning)
            }
        }
        notifySubscribers()
        return result
    }

    private func retainUnsaved(_ entry: RecordingEntry, warning: String) -> RecordingEntry {
        var updated = entry
        updated.assessCapabilities()
        updated.persistenceWarning = warning
        let id = canonicalURL(entry.recording)
        entriesMap[id] = updated
        revisions[id, default: 0] += 1
        unsavedEntries.insert(id)
        lastError = warning
        return updated
    }

    /// Mutates an entry in place and persists changes within a single serialized transaction.
    @discardableResult
    public func updateThrowing(_ url: URL, _ change: (inout RecordingEntry) -> Void) throws -> RecordingEntry {
        try RecordingPaths.requireStandardLayout(url)
        let (savedEntry, shouldNotify) = try withLock {
            guard var target = lockedEntry(url) else {
                throw TranscriptStorageError.metadataNotFound(url.path)
            }
            change(&target)
            let saved = try lockedPutThrowing(target, persist: true)
            return (saved, true)
        }
        if shouldNotify {
            notifySubscribers()
        }
        return savedEntry
    }

    /// Safe version of update that records persistence warning on error without throwing or losing memory state.
    @discardableResult
    public func update(_ url: URL, _ change: (inout RecordingEntry) -> Void) -> HistoryPersistenceResult<RecordingEntry?> {
        do {
            return HistoryPersistenceResult(value: try updateThrowing(url, change))
        } catch {
            let warning = "Не удалось сохранить историю. Аудио не удалено: " + error.localizedDescription
            withLock { lastError = warning }
            return HistoryPersistenceResult(value: entry(url), persistenceWarning: warning)
        }
    }

    /// Lifecycle status must remain observable even when its durable save fails.
    @discardableResult
    public func updateStatus(_ url: URL, _ change: (inout RecordingEntry) -> Void) -> HistoryPersistenceResult<RecordingEntry?> {
        guard RecordingPaths.isStandardLayout(url) else {
            return HistoryPersistenceResult(value: entry(url), persistenceWarning: RecordingPaths.unsupportedLayoutMessage)
        }
        let result: HistoryPersistenceResult<RecordingEntry?> = withLock {
            guard var target = lockedEntry(url) else {
                return HistoryPersistenceResult(value: nil, persistenceWarning: "Запись не найдена: " + url.path)
            }
            change(&target)
            do {
                return HistoryPersistenceResult(value: try lockedPutThrowing(target))
            } catch {
                let warning = "Не удалось сохранить историю. Аудио не удалено: " + error.localizedDescription
                return HistoryPersistenceResult(value: retainUnsaved(target, warning: warning), persistenceWarning: warning)
            }
        }
        notifySubscribers()
        return result
    }

    /// Cancels a short recording by moving its dedicated directory to Trash.
    /// Strict guards: finite duration >= 0 and < 10, phase must be .recording,
    /// directory name must start with "meeting_" and match base filename (no legacy/shared day folder deletion).
    public func cancelShortRecording(
        _ url: URL,
        duration: Double,
        trash: ((URL) throws -> Void)? = nil
    ) throws -> Bool {
        guard duration.isFinite, duration >= 0, duration < 10 else { return false }
        guard let existing = entry(url), existing.phase == .recording,
              existing.folder.lastPathComponent.hasPrefix("meeting_"),
              existing.folder.lastPathComponent == existing.base.lastPathComponent else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let doTrash = trash ?? { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        try doTrash(existing.folder)

        let canonical = canonicalURL(url)
        withLock {
            revisions[canonical, default: 0] += 1
            entriesMap.removeValue(forKey: canonical)
        }
        notifySubscribers()
        return true
    }

    /// Scans a directory recursively for recordings and returns entries + possible scanning error.
    public func scanRecordings(in directory: URL) -> (entries: [RecordingEntry], error: String?) {
        var files = Set<URL>()
        var failure: String?
        guard fileManager.fileExists(atPath: directory.path) else { return ([], nil) }

        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                failure = error.localizedDescription
                return true
            }
        )

        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if url.lastPathComponent == "raw" || url.lastPathComponent == "experiments" {
                    enumerator?.skipDescendants()
                    continue
                }
                if url.lastPathComponent.hasPrefix("meeting_") {
                    files.insert(url.appendingPathComponent(url.lastPathComponent + ".m4a"))
                }
            } else {
                let name = url.lastPathComponent
                guard name.hasPrefix("meeting_") else { continue }
                for suffix in [".m4a", ".sources.transcript.txt", ".context.json", ".host_record.wav"] where name.hasSuffix(suffix) {
                    files.insert(url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(suffix.count)) + ".m4a"))
                    break
                }
            }
        }

        return (files.map { url in
            var entry = RecordingEntry.load(recording: url)
            if entry.phase.isWorking { entry.phase = .interrupted }
            return entry
        }, failure)
    }

    /// Refreshes entries from disk, guarding against overwriting active jobs or concurrent updates.
    public func refresh(root: URL) async -> (entries: [RecordingEntry], error: String?) {
        let (requestGeneration, beforeRevisions) = withLock { () -> (Int, [URL: Int]) in
            generation += 1
            return (generation, revisions)
        }

        let scanResult = scanRecordings(in: root)

        let (sorted, errorToReport, subscribersToNotify) = withLock { () -> ([RecordingEntry], String?, [@Sendable ([RecordingEntry]) -> Void]) in
            guard requestGeneration == generation else {
                return (entriesMap.values.sorted { $0.date > $1.date }, nil, [])
            }

            for scanned in scanResult.entries {
                let id = scanned.id
                if revisions[id] == beforeRevisions[id] {
                    if entriesMap[id]?.phase.isWorking == true || unsavedEntries.contains(id) { continue }
                    revisions[id, default: 0] += 1
                    entriesMap[id] = scanned
                }
            }

            let sorted = entriesMap.values.sorted { $0.date > $1.date }
            let error = scanResult.error.map { "Не удалось прочитать часть истории: " + $0 }
            self.lastError = error
            return (sorted, error, self.subscribers)
        }

        for subscriber in subscribersToNotify { subscriber(sorted) }
        notifySubscribers()

        return (sorted, errorToReport)
    }
}
