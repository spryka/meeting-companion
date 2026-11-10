import Foundation
import Testing
import MeetingCompanionCore
@testable import MeetingCompanionApplication

struct LibraryRefreshTests {
    @Test(arguments: [false, true], [false, true])
    func completeRefreshRemovesExternallyMovedRecordings(flat: Bool, keepOther: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temporary.appendingPathComponent("library")
        let folder = root.appendingPathComponent(flat ? "day" : "day/meeting_removed")
        let recording = folder.appendingPathComponent("meeting_removed.m4a")
        let kept = root.appendingPathComponent("meeting_kept/meeting_kept.m4a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: recording)
        try Data("Saved transcript".utf8).write(to: recording.deletingPathExtension().appendingPathExtension("sources.transcript.txt"))
        if keepOther {
            try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([4, 5, 6]).write(to: kept)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = RecordingHistoryRepository()
        _ = await repository.refresh(root: root)
        let beforeRevision = repository.snapshot().revision
        try FileManager.default.moveItem(at: folder, to: temporary.appendingPathComponent("moved"))

        let result = await repository.refresh(root: root)

        #expect(result.error == nil)
        #expect(Set(result.entries.map(\.id)) == (keepOther ? [kept] : []))
        #expect(repository.entry(recording) == nil)
        #expect(repository.snapshot().revision > beforeRevision)
        #expect(try Data(contentsOf: temporary.appendingPathComponent("moved/meeting_removed.m4a")) == Data([1, 2, 3]))
        if keepOther { #expect(try Data(contentsOf: kept) == Data([4, 5, 6])) }

        try FileManager.default.moveItem(at: temporary.appendingPathComponent("moved"), to: folder)
        _ = await repository.refresh(root: root)
        let restored = await repository.refresh(root: root)
        #expect(restored.entries.filter { $0.id == recording }.count == 1)
    }

    @Test(arguments: ["recording", "processing", "work", "trash", "unsaved"])
    func completeRefreshKeepsProtectedMissingEntries(protection: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("meeting_protected")
        let recording = folder.appendingPathComponent("meeting_protected.m4a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: recording)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RecordingHistoryRepository()
        _ = await repository.refresh(root: root)
        var entry = try #require(repository.entry(recording))
        let work = UUID()
        var trash: (RecordingTrashTarget, UUID)?
        switch protection {
        case "recording", "processing":
            entry.phase = protection == "recording" ? .recording : .processing
            _ = try repository.putThrowing(entry, persist: false)
        case "work":
            #expect(repository.reserveWork(recording, id: work))
        case "trash":
            let target = try repository.prepareTrash(recording, root: root)
            trash = (target, try repository.reserveTrash(target))
        default:
            try Data().write(to: folder.appendingPathComponent("raw"))
            #expect(repository.put(entry).persistenceWarning != nil)
        }
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent(".moved"))

        let result = await repository.refresh(root: root)

        #expect(result.error == nil)
        #expect(result.entries.map(\.id) == [recording])
        #expect(repository.entry(recording)?.phase == entry.phase)
        if protection == "unsaved" {
            #expect(repository.entry(recording)?.persistenceWarning != nil)
        } else {
            repository.releaseWork(recording, id: work)
            if let (target, token) = trash { repository.releaseTrash(target, id: token) }
            entry.phase = .completed
            _ = try repository.putThrowing(entry, persist: false)
            let unprotected = await repository.refresh(root: root)
            #expect(unprotected.entries.isEmpty)
        }
    }

    @Test func partialRefreshKeepsMissingRowsAndAddsReadableRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = root.appendingPathComponent("meeting_missing/meeting_missing.m4a")
        let readable = root.appendingPathComponent("meeting_readable/meeting_readable.m4a")
        try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: missing)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RecordingHistoryRepository()
        _ = await repository.refresh(root: root)
        try FileManager.default.moveItem(at: missing.deletingLastPathComponent(), to: root.appendingPathComponent(".moved"))
        try FileManager.default.createDirectory(at: readable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: readable)
        let enumerate = repository.historyEnumerator
        repository.historyEnumerator = { directory, handler in
            _ = handler(directory.appendingPathComponent("unreadable"), CocoaError(.fileReadNoPermission))
            return enumerate(directory, handler)
        }

        let result = await repository.refresh(root: root)

        #expect(result.error != nil)
        #expect(Set(result.entries.map(\.id)) == [missing, readable])
    }

    @Test(arguments: [false, true])
    func missingRootPreservesExistingRows(allowMissingRoot: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temporary.appendingPathComponent("library")
        let recording = root.appendingPathComponent("meeting_missing/meeting_missing.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: recording)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = RecordingHistoryRepository()
        _ = await repository.refresh(root: root)
        try FileManager.default.moveItem(at: root, to: temporary.appendingPathComponent("moved"))

        let result = await repository.refresh(root: root, allowMissingRoot: allowMissingRoot)

        #expect(result.entries.map(\.id) == [recording])
        if !allowMissingRoot { #expect(result.error != nil) }
    }

    @Test func refreshPreservesConcurrentAndOutOfRootEntries() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temporary.appendingPathComponent("library")
        let recording = root.appendingPathComponent("meeting_changed/meeting_changed.m4a")
        let loadedLater = root.appendingPathComponent("meeting_later/meeting_later.m4a")
        let outside = temporary.appendingPathComponent("library-other/meeting_outside/meeting_outside.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: recording)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = RecordingHistoryRepository()
        _ = await repository.refresh(root: root)
        _ = try repository.putThrowing(RecordingEntry(recording: outside, date: Date(), title: "Outside", phase: .completed), persist: false)
        let request = repository.beginRefresh()
        var changed = try #require(repository.entry(recording))
        changed.displayTitle = "Changed after scan started"
        _ = try repository.putThrowing(changed, persist: false)
        try FileManager.default.moveItem(at: recording.deletingLastPathComponent(), to: temporary.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: loadedLater.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: loadedLater)
        #expect(repository.entry(loadedLater) != nil)
        try FileManager.default.moveItem(at: loadedLater.deletingLastPathComponent(), to: temporary.appendingPathComponent("later"))

        let concurrent = await repository.refresh(root: root, request: request)

        #expect(Set(concurrent.entries.map(\.id)) == [recording, loadedLater, outside])
        #expect(repository.entry(recording)?.displayTitle == changed.displayTitle)
        let next = await repository.refresh(root: root)
        #expect(next.entries.map(\.id) == [outside])
    }

    @Test func partialEnumerationReportsErrorAndKeepsReadableEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recording = root.appendingPathComponent("meeting_readable/meeting_readable.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: recording)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RecordingHistoryRepository()
        let enumerate = repository.historyEnumerator
        repository.historyEnumerator = { directory, handler in
            _ = handler(directory.appendingPathComponent("unreadable"), CocoaError(.fileReadNoPermission))
            return enumerate(directory, handler)
        }
        let result = await repository.refresh(root: root)
        #expect(result.error != nil)
        #expect(result.entries.map(\.id) == [RecordingEntry.canonicalURL(recording)])
    }

    @Test func missingEnumeratorReportsFailureAndKeepsPreviousEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RecordingHistoryRepository()
        repository.historyEnumerator = { _, _ in nil }
        let recording = root.appendingPathComponent("meeting_saved/meeting_saved.m4a")
        _ = try repository.putThrowing(RecordingEntry(recording: recording, date: Date(), title: "Saved", phase: .completed), persist: false)
        let result = await repository.refresh(root: root)
        #expect(result.error != nil)
        #expect(result.entries.map(\.id) == [recording])
    }

    @Test func missingRootReportsFailure() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = await RecordingHistoryRepository().refresh(root: root)
        #expect(result.error != nil)
    }

    @Test func fileInsteadOfRootReportsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let repository = RecordingHistoryRepository()
        let result = await repository.refresh(root: root)
        #expect(result.error != nil)
        #expect(result.entries.isEmpty)
    }
    @Test func staleScanCannotOverwriteNewerRequestOrMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("meeting_test/meeting_test.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data().write(to: recording)
        let repository = RecordingHistoryRepository()
        _ = await repository.refresh(root: root)
        let stale = repository.beginRefresh()
        let current = repository.beginRefresh()
        _ = await repository.refresh(root: root, request: current)
        _ = try repository.updateThrowing(recording, { $0.phase = .processing })
        _ = await repository.refresh(root: root, request: stale)
        #expect(repository.entry(recording)?.phase == .processing)
        let beforeUpdate = repository.beginRefresh()
        _ = try repository.updateThrowing(recording, { $0.phase = .recording })
        _ = await repository.refresh(root: root, request: beforeUpdate)
        #expect(repository.entry(recording)?.phase == .recording)
    }

    @Test func restoredFolderIsRediscoveredExactlyOnceWithoutChangingSavedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting_restore")
        let recording = folder.appendingPathComponent("meeting_restore.m4a")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: recording)
        let repository = RecordingHistoryRepository()
        var entry = RecordingEntry(recording: recording, date: Date(), title: "Restored", phase: .completed)
        entry.displayTitle = "Saved display title"
        _ = try repository.putThrowing(entry)
        let metadata = try Data(contentsOf: entry.metadata)
        let target = try repository.prepareTrash(recording, root: root)
        let reservation = try repository.reserveTrash(target)
        let oldRequest = repository.beginRefresh()
        let trash = root.appendingPathComponent(".test-trash")
        #expect(try repository.trash(target, reservation: reservation, operation: { try FileManager.default.moveItem(at: $0, to: trash) }) == .moved)
        _ = await repository.refresh(root: root, request: oldRequest)
        #expect(repository.entry(recording) == nil)
        try FileManager.default.moveItem(at: trash, to: folder)
        _ = await repository.refresh(root: root)
        _ = await repository.refresh(root: root)
        #expect(repository.allEntries().count == 1)
        #expect(repository.entry(recording)?.displayTitle == "Saved display title")
        #expect(try Data(contentsOf: entry.metadata) == metadata)
        #expect(try Data(contentsOf: recording) == Data([1, 2, 3]))
    }
}
