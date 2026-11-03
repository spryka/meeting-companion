import Combine
import Foundation
import MeetingCompanionCore
import MeetingCompanionApplication

/// UI consumes prepared snapshots; all repository disk operations are awaited off MainActor.
@MainActor
public final class RecordingHistory: ObservableObject {
    @Published public private(set) var entries: [RecordingEntry] = []
    @Published public private(set) var loading = false
    @Published public private(set) var initialLoadComplete = false
    @Published public private(set) var error: String?
    @Published public var progress: [URL: TranscriptionProgress] = [:]
    public let repository: RecordingHistoryRepository
    private var revision = -1
    private var observation: Task<Void, Never>?

    public init(repository: RecordingHistoryRepository = RecordingHistoryRepository()) {
        self.repository = repository
        observation = Task { [weak self] in
            let stream = await Task.detached { repository.observeSnapshots() }.value
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.apply(snapshot)
            }
        }
    }

    deinit { observation?.cancel() }

    private func apply(_ snapshot: RecordingHistoryRepository.Snapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        entries = snapshot.entries
        if let warning = entries.compactMap(\.persistenceWarning).first { error = warning }
    }

    public func synchronize() async {
        let repository = repository
        apply(await Task.detached { repository.snapshot() }.value)
    }

    public func reportError(_ message: String) { error = message }
    public func clearError() { error = nil }
    public func entry(_ url: URL) -> RecordingEntry? { entries.first { $0.id == url } }

    public func refresh(root: URL) async {
        loading = true
        defer { loading = false; initialLoadComplete = true }
        let result = await repository.refresh(root: root)
        await synchronize()
        if let failure = result.error { error = failure }
    }

    public func putThrowing(_ entry: RecordingEntry, persist: Bool = true) async throws {
        let repository = repository
        try await Task.detached { _ = try repository.putThrowing(entry, persist: persist) }.value
        await synchronize()
    }

    public func put(_ entry: RecordingEntry, persist: Bool = true) async {
        let repository = repository
        let result = await Task.detached { repository.put(entry, persist: persist) }.value
        await synchronize()
        if let warning = result.persistenceWarning { error = warning }
    }

    public func updateThrowing(_ url: URL, _ change: @escaping @Sendable (inout RecordingEntry) -> Void) async throws {
        let repository = repository
        try await Task.detached { _ = try repository.updateThrowing(url, change) }.value
        await synchronize()
    }

    public func update(_ url: URL, _ change: @escaping @Sendable (inout RecordingEntry) -> Void) async {
        let repository = repository
        let result = await Task.detached { repository.update(url, change) }.value
        await synchronize()
        if let warning = result.persistenceWarning { error = warning }
    }

    public func updateStatus(_ url: URL, _ change: @escaping @Sendable (inout RecordingEntry) -> Void) async {
        let repository = repository
        let result = await Task.detached { repository.updateStatus(url, change) }.value
        await synchronize()
        if let warning = result.persistenceWarning { error = warning }
    }

}
