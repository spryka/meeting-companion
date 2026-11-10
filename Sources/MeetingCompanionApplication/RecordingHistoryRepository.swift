import Foundation
import Darwin
import MeetingCompanionCore

public struct RecordingTrashTarget: Sendable, Equatable {
    public let recording: URL
    public let folder: URL
    public let root: URL
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    fileprivate let rootDevice: dev_t
    fileprivate let rootInode: ino_t
}

public struct RecordingTrashFailure: LocalizedError, Sendable {
    public let message: String
    public let retryAllowed: Bool
    public var errorDescription: String? { message }
}

public enum RecordingTrashOutcome: Sendable, Equatable {
    case moved
    case unconfirmed(String)
}

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
    private var unsavedEntries: Set<URL> = []
    private var workReservations: [URL: Set<UUID>] = [:]
    private var trashReservations: [URL: UUID] = [:]
    private var runningTrash: Set<UUID> = []
    // Test seam for substitution during filesystem traversal, before the final identity check.
    var trashValidationDidScan: (@Sendable () throws -> Void)?
    private let fileManager = FileManager.default
    var historyEnumerator: (URL, @escaping (URL, any Error) -> Bool) -> FileManager.DirectoryEnumerator? = { directory, handler in
        FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles], errorHandler: handler)
    }
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
        guard allowsHistoryMutation(canonical) else { return nil }
        if fileManager.fileExists(atPath: canonical.path) {
            let loaded = RecordingEntry.load(recording: canonical)
            entriesMap[canonical] = loaded
            return loaded
        }
        return nil
    }

    /// Internal put implementation. Caller MUST hold lock.
    private func lockedPutThrowing(_ entry: RecordingEntry, persist: Bool = true, preserveTitle: Bool = true) throws -> RecordingEntry {
        let canonical = canonicalURL(entry.recording)
        guard allowsHistoryMutation(canonical) else { throw trashBusyError }
        var updatedEntry = entry
        if updatedEntry.recording != canonical {
            updatedEntry = RecordingEntry(recording: canonical, date: entry.date, title: entry.title, phase: entry.phase)
            updatedEntry.displayTitle = entry.displayTitle
            updatedEntry.duration = entry.duration
            updatedEntry.problems = entry.problems
            updatedEntry.meeting = entry.meeting
            updatedEntry.log = entry.log
        }

        // Lifecycle callers may have captured an entry before a successful rename.
        if preserveTitle { updatedEntry.displayTitle = entriesMap[canonical]?.displayTitle ?? RecordingEntry.load(recording: canonical).displayTitle ?? updatedEntry.displayTitle }
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

    // Shares rename's transaction lock; callers retain ownership through awaited teardown.
    @discardableResult
    public func reserveWork(_ url: URL, id: UUID) -> Bool {
        withLock {
            let key = canonicalURL(url)
            guard allowsHistoryMutation(key) else { return false }
            workReservations[key, default: []].insert(id)
            return true
        }
    }

    public func releaseWork(_ url: URL, id: UUID) {
        withLock {
            let key = canonicalURL(url)
            workReservations[key]?.remove(id)
            if workReservations[key]?.isEmpty == true { workReservations.removeValue(forKey: key) }
        }
    }

    public func prepareTrash(_ url: URL, root: URL) throws -> RecordingTrashTarget {
        try withLock {
            guard let entry = lockedEntry(url) else { throw CocoaError(.fileNoSuchFile) }
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            // Keep the supplied path until symlink checks; canonicalizing first hides substitution.
            let folder = url.deletingLastPathComponent().standardizedFileURL
            let status = try directoryIdentity(folder), rootStatus = try directoryIdentity(root)
            let target = RecordingTrashTarget(recording: entry.id, folder: folder, root: root,
                device: status.st_dev, inode: status.st_ino, rootDevice: rootStatus.st_dev, rootInode: rootStatus.st_ino)
            try validateTrash(target)
            return target
        }
    }

    public func reserveTrash(_ target: RecordingTrashTarget) throws -> UUID {
        try withLock {
            try validateTrash(target)
            let id = UUID()
            trashReservations[target.recording] = id
            return id
        }
    }

    public func releaseTrash(_ target: RecordingTrashTarget, id: UUID) {
        withLock {
            if !runningTrash.contains(id), trashReservations[target.recording] == id {
                trashReservations.removeValue(forKey: target.recording)
            }
        }
    }

    public func trash(_ target: RecordingTrashTarget, reservation: UUID,
                      operation: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> RecordingTrashOutcome {
        try withLock {
            guard !runningTrash.contains(reservation) else { throw trashBusyError }
            do { try validateTrash(target, reservation: reservation) }
            catch {
                if trashReservations[target.recording] == reservation { trashReservations.removeValue(forKey: target.recording) }
                throw error
            }
            runningTrash.insert(reservation)
        }
        defer {
            withLock {
                runningTrash.remove(reservation)
                if trashReservations[target.recording] == reservation { trashReservations.removeValue(forKey: target.recording) }
            }
        }
        let writer = TranscriptEditsRepository(recordingDirectory: target.folder)
        do { try writer.acquireWriteLock() }
        catch { throw RecordingTrashFailure(message: error.localizedDescription, retryAllowed: true) }
        defer { writer.releaseWriteLock() }
        // No async handoff between the last identity check and the native path operation.
        try withLock { try validateTrash(target, reservation: reservation) }
        let outcome: RecordingTrashOutcome
        do {
            try operation(target.folder)
            guard !fileManager.fileExists(atPath: target.folder.path) else {
                throw RecordingTrashFailure(message: "Исходная папка осталась на диске. Обновите библиотеку и повторите действие.", retryAllowed: false)
            }
            outcome = .moved
        } catch {
            var status = stat()
            if lstat(target.folder.path, &status) != 0, errno == ENOENT {
                outcome = .unconfirmed(error.localizedDescription)
            } else {
                let same = status.st_dev == target.device && status.st_ino == target.inode
                throw RecordingTrashFailure(message: error.localizedDescription, retryAllowed: same && !(error is RecordingTrashFailure))
            }
        }
        withLock {
            generation += 1
            revisions[target.recording, default: 0] += 1
            entriesMap.removeValue(forKey: target.recording)
            unsavedEntries.remove(target.recording)
        }
        notifySubscribers()
        return outcome
    }

    private var trashBusyError: RecordingTrashFailure {
        RecordingTrashFailure(message: "Дождитесь завершения работы с записью", retryAllowed: false)
    }

    private func allowsHistoryMutation(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().path
        guard !trashReservations.keys.contains(where: { foldersOverlap(folder, $0.deletingLastPathComponent().path) }) else { return false }
        // Existing revision is enough to reject a late put after removal; a restored folder is discoverable normally.
        return !(revisions[url] != nil && entriesMap[url] == nil && !fileManager.fileExists(atPath: folder))
    }

    private func foldersOverlap(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private func directoryIdentity(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw RecordingTrashFailure(message: "Доступно только для записи в отдельной папке", retryAllowed: false)
        }
        return value
    }

    private func validateTrash(_ target: RecordingTrashTarget, reservation: UUID? = nil) throws {
        let folder = target.folder.path
        guard RecordingPaths.isStandardLayout(target.recording),
              target.folder.lastPathComponent == target.recording.deletingPathExtension().lastPathComponent,
              folder.hasPrefix(target.root.path + "/"),
              target.folder.lastPathComponent.range(of: #"^(\d{2}|\d{4}-\d{2})$"#, options: .regularExpression) == nil else {
            throw RecordingTrashFailure(message: "Доступно только для записи в отдельной папке", retryAllowed: false)
        }
        try validateTrashIdentity(target)
        guard let entry = entriesMap[target.recording], !entry.phase.isWorking,
              !workReservations.contains(where: { !$0.value.isEmpty && foldersOverlap(folder, $0.key.deletingLastPathComponent().path) }),
              !trashReservations.contains(where: {
                  !($0.key == target.recording && $0.value == reservation) && foldersOverlap(folder, $0.key.deletingLastPathComponent().path)
              }),
              trashReservations[target.recording] == reservation else { throw trashBusyError }
        guard !entriesMap.keys.contains(where: { $0 != target.recording && $0.path.hasPrefix(folder + "/") }) else {
            throw RecordingTrashFailure(message: "Папка содержит другую запись или её принадлежность неоднозначна.", retryAllowed: false)
        }
        try validateExclusiveOwnership(target)
        try trashValidationDidScan?()
        try validateTrashIdentity(target)
    }

    private func validateTrashIdentity(_ target: RecordingTrashTarget) throws {
        let status = try directoryIdentity(target.folder), rootStatus = try directoryIdentity(target.root)
        guard target.folder.resolvingSymlinksInPath().path == target.folder.path,
              target.root.resolvingSymlinksInPath().path == target.root.path,
              status.st_dev == target.device, status.st_ino == target.inode,
              rootStatus.st_dev == target.rootDevice, rootStatus.st_ino == target.rootInode else {
            throw RecordingTrashFailure(message: "Папка записи изменилась. Отмените действие и обновите библиотеку.", retryAllowed: false)
        }
    }

    private func validateExclusiveOwnership(_ target: RecordingTrashTarget) throws {
        var failure: Error?
        guard let items = fileManager.enumerator(at: target.folder, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        let stem = target.recording.deletingPathExtension().lastPathComponent
        for case let url as URL in items {
            var status = stat()
            guard lstat(url.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if status.st_mode & S_IFMT == S_IFLNK { continue }
            let name = url.lastPathComponent
            if status.st_mode & S_IFMT == S_IFDIR {
                if name.hasPrefix("meeting_") { throw RecordingTrashFailure(message: "Папка содержит другую запись.", retryAllowed: false) }
                continue
            }
            for suffix in [".sources.transcript.txt", ".host_record.aec.wav", ".host_record.wav", ".remote_record.wav", ".processing.json", ".context.json", ".m4a", ".mp4", ".wav"] where name.hasSuffix(suffix) {
                let candidate = String(name.dropLast(suffix.count)), parent = url.deletingLastPathComponent()
                let parentIdentity = try directoryIdentity(parent)
                let inRoot = parentIdentity.st_dev == target.device && parentIdentity.st_ino == target.inode
                let inRaw: Bool
                if parent.lastPathComponent == "raw" {
                    let grandparent = try directoryIdentity(parent.deletingLastPathComponent())
                    inRaw = grandparent.st_dev == target.device && grandparent.st_ino == target.inode
                } else { inRaw = false }
                if candidate == stem, inRoot || inRaw { break }
                if candidate.hasPrefix("meeting_") || parent.lastPathComponent == candidate
                    || parent.lastPathComponent == "raw" && parent.deletingLastPathComponent().lastPathComponent == candidate
                    || (inRoot || inRaw) && suffix != ".wav" {
                    throw RecordingTrashFailure(message: "Неоднозначная принадлежность файла: " + url.path, retryAllowed: false)
                }
                break
            }
        }
        if let failure { throw failure }
    }

    @discardableResult
    public func rename(_ url: URL, displayTitle: String) throws -> RecordingEntry {
        try RecordingPaths.requireStandardLayout(url)
        let name = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120,
              !displayTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TranscriptEditsError.malformed("Название: от 1 до 120 символов, без управляющих символов.")
        }
        let saved = try withLock {
            guard var target = lockedEntry(url) else { throw TranscriptStorageError.metadataNotFound(url.path) }
            guard !target.phase.isWorking, workReservations[canonicalURL(url), default: []].isEmpty else { throw TranscriptEditsError.conflict("Дождитесь завершения работы с записью.") }
            guard target.effectiveTitle != name else { return target }
            target.displayTitle = name
            return try lockedPutThrowing(target, preserveTitle: false)
        }
        notifySubscribers()
        return saved
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
                if !RecordingPaths.isStandardLayout(entry.recording) || !allowsHistoryMutation(canonicalURL(entry.recording)) {
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
        updated.displayTitle = entriesMap[canonicalURL(entry.recording)]?.displayTitle ?? entry.displayTitle
        updated.assessCapabilities()
        updated.persistenceWarning = warning
        let id = canonicalURL(entry.recording)
        entriesMap[id] = updated
        revisions[id, default: 0] += 1
        unsavedEntries.insert(id)
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
            guard allowsHistoryMutation(canonicalURL(url)) else {
                return HistoryPersistenceResult(value: entriesMap[canonicalURL(url)], persistenceWarning: trashBusyError.message)
            }
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

        guard let enumerator = historyEnumerator(directory, { _, error in
            failure = error.localizedDescription
            return true
        }) else { return ([], failure ?? "Папка записей недоступна.") }

        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if url.lastPathComponent == "raw" || url.lastPathComponent == "experiments" {
                    enumerator.skipDescendants()
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
    public struct RefreshRequest: Sendable {
        fileprivate let generation: Int
        fileprivate let revisions: [URL: Int]
        fileprivate let entries: Set<URL>
    }

    /// Reserve ordering before handing filesystem work to another executor.
    public func beginRefresh() -> RefreshRequest {
        withLock {
            generation += 1
            return RefreshRequest(generation: generation, revisions: revisions, entries: Set(entriesMap.keys))
        }
    }

    public func refresh(root: URL, request: RefreshRequest? = nil, allowMissingRoot: Bool = false,
                        preservingMissing: @Sendable () async -> Set<URL> = { [] }) async -> (entries: [RecordingEntry], error: String?) {
        let request = request ?? beginRefresh()
        var scanResult = scanRecordings(in: root)
        if !allowMissingRoot, !fileManager.fileExists(atPath: root.path) {
            scanResult.error = "Папка записей недоступна."
        }
        let scannedIDs = Set(scanResult.entries.map(\.id))
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let canPrune = scanResult.error == nil && fileManager.fileExists(atPath: root.path)
        let protectedIDs: Set<URL>
        if canPrune, withLock({ request.generation == generation }) {
            protectedIDs = await preservingMissing()
        } else {
            protectedIDs = []
        }

        let (sorted, errorToReport, subscribersToNotify) = withLock { () -> ([RecordingEntry], String?, [@Sendable ([RecordingEntry]) -> Void]) in
            guard request.generation == generation else {
                return (entriesMap.values.sorted { $0.date > $1.date }, nil, [])
            }

            if canPrune {
                for id in request.entries where id.pathComponents.starts(with: rootComponents)
                    && !scannedIDs.contains(id) && !protectedIDs.contains(id) {
                    guard let entry = entriesMap[id], revisions[id] == request.revisions[id],
                          !entry.phase.isWorking, !unsavedEntries.contains(id), allowsHistoryMutation(id),
                          !workReservations.contains(where: {
                              !$0.value.isEmpty && foldersOverlap(id.deletingLastPathComponent().path, $0.key.deletingLastPathComponent().path)
                          }) else { continue }
                    entriesMap.removeValue(forKey: id)
                    // Keep a newer revision so UI snapshots and late writers cannot resurrect the row.
                    revisions[id, default: 0] += 1
                }
            }

            for scanned in scanResult.entries {
                let id = scanned.id
                if revisions[id] == request.revisions[id] {
                    if entriesMap[id]?.phase.isWorking == true || unsavedEntries.contains(id) || !allowsHistoryMutation(id) { continue }
                    revisions[id, default: 0] += 1
                    entriesMap[id] = scanned
                }
            }

            let sorted = entriesMap.values.sorted { $0.date > $1.date }
            let error = scanResult.error.map { "Не удалось прочитать часть истории: " + $0 }
            return (sorted, error, self.subscribers)
        }

        for subscriber in subscribersToNotify { subscriber(sorted) }
        notifySubscribers()

        return (sorted, errorToReport)
    }
}
