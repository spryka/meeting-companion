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
    @Published public private(set) var notice: String?
    @Published public var progress: [URL: TranscriptionProgress] = [:]
    public let repository: RecordingHistoryRepository
    @Published public private(set) var refreshError: String?
    @Published public private(set) var refreshCompletion: UUID?
    private var refreshRequest: UUID?
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
    public func reportNotice(_ message: String) { notice = message }
    public func clearNotice() { notice = nil }
    public func entry(_ url: URL) -> RecordingEntry? { entries.first { $0.id == url } }

    func invalidateRefresh() {
        refreshRequest = nil
        _ = repository.beginRefresh()
        loading = false
        refreshError = nil
        refreshCompletion = nil
    }

    public func refresh(root: URL, manual: Bool = false) async {
        let id = UUID(), repository = repository
        refreshRequest = id
        let request = repository.beginRefresh()
        loading = true
        refreshError = nil
        let result = await Task.detached {
            await repository.refresh(root: root, request: request, allowMissingRoot: !manual)
        }.value
        guard refreshRequest == id else { return }
        await synchronize()
        guard refreshRequest == id else { return }
        loading = false
        initialLoadComplete = true
        if manual {
            refreshError = result.error.map { "Не удалось полностью обновить библиотеку. Повторите обновление. " + $0 }
            if result.error == nil { refreshCompletion = id }
        } else if let failure = result.error { error = failure }
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

    public func rename(_ url: URL, displayTitle: String) async throws {
        let repository = repository
        _ = try await Task.detached { try repository.rename(url, displayTitle: displayTitle) }.value
        await synchronize()
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

extension Date {
    public var dateGroupTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return "Сегодня"
        } else if calendar.isDateInYesterday(self) {
            return "Вчера"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM"
            return formatter.string(from: self)
        }
    }
}

extension RecordingEntry {
    public var dateGroupTitle: String {
        date.dateGroupTitle
    }
}
